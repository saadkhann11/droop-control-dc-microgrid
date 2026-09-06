function build_02_droop_wiring(mdl)
%PHASE4_WIRE_DROOP  Connect the Phase 3 droop nodes to the Phase 4 supervisor.
%
%  Two changes per node, and nothing else:
%
%   1. the droop set-point V0 stops being the fixed Vdc_ref constant and
%      becomes the supervisor's V0bat / V0grid signal;
%   2. a Saturation Dynamic is inserted on the node's OUTPUT, driven by the
%      supervisor's current limits.
%
%  Deliberately NOT done: changing the DC Droop Node library block's
%  interface.  Its Imin/Imax remain the converter's physical rating - the
%  hardware limit - and the supervisor's policy limit is applied outside it.
%  Two limits in series, of two different kinds, each visible on its own.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');

NL  = char(10);
bat = [mdl '/Bidirectional DC//DC' NL ' Converter'];
bcc = [bat '/Battery Converter' NL ' Control'];
drc = [mdl '/DROOP CONTROLLER'];

%% ---- 1. battery set-point: top-level Vdc_ref  ->  From V0bat -----------
%  The battery converter takes its set-point through inport 1 of the
%  Bidirectional DC/DC Converter, so the swap is made at the top level and
%  the subsystem interface is untouched.
ph  = get_param(bat,'PortHandles');
lin = get_param(ph.Inport(1),'Line');
if lin > 0
    sb = get_param(lin,'SrcBlockHandle');
    if sb > 0 && strcmp(get_param(sb,'Name'),'Vdc_ref')
        delete_line(lin);
    end
end
src = [mdl '/From V0bat'];
if getSimulinkBlockHandle(src) <= 0
    p = get_param(bat,'Position');
    add_block('simulink/Signal Routing/From', src, ...
              'Position', [p(1)-140 p(2)+20 p(1)-70 p(2)+40], ...
              'GotoTag','V0bat');
end
% connect by port handle - the block name contains a '/', which cannot be
% written in a 'Block/port' string without escaping it
if get_param(get_param(bat,'PortHandles').Inport(1),'Line') <= 0
    add_line(mdl, get_param(src,'PortHandles').Outport(1), ...
                  get_param(bat,'PortHandles').Inport(1), 'autorouting','on');
end

%% ---- 2. grid set-point: retarget the existing From ---------------------
%  DROOP CONTROLLER/From already carries the set-point into the grid droop
%  node; only the tag it listens to changes.
set_param([drc '/From'],'GotoTag','V0grid');

%% ---- 3. policy limiters on both droop node outputs ---------------------
insertLimiter(bcc, 'Battery Droop', 'Ibat_hi', 'Ibat_lo', 'Ibat limit');
insertLimiter(drc, 'Grid Droop',    'Igrid_hi','Igrid_lo','Igrid limit');

fprintf('build_02_droop_wiring: battery + grid droop nodes wired to the supervisor\n');
end

% -------------------------------------------------------------------------
function insertLimiter(sys, nodeName, tagHi, tagLo, satName)
%INSERTLIMITER  Put a Saturation Dynamic on the output of a droop node.
%  Everything the node used to feed is fed from the LIMITED signal instead,
%  so the logged reference is the one the inner current loop actually gets.
sat = [sys '/' satName];
if getSimulinkBlockHandle(sat) > 0
    return                      % already inserted
end

node = [sys '/' nodeName];
p    = get_param(node,'Position');
out  = get_param(node,'PortHandles').Outport(1);
lin  = get_param(out,'Line');
assert(lin > 0, 'droop node %s has no output line', node);

dstB = get_param(lin,'DstBlockHandle');
dstP = get_param(lin,'DstPortHandle');
dst  = cell(0,2);
for k = 1:numel(dstB)
    if dstB(k) > 0
        pn = get_param(dstP(k),'PortNumber');
        if ischar(pn), pn = str2double(pn); end
        dst(end+1,:) = {get_param(dstB(k),'Name'), pn};  %#ok<AGROW>
    end
end
delete_line(lin);

x = p(3) + 90;  y = p(2);
add_block('simulink/Discontinuities/Saturation Dynamic', sat, ...
          'Position',[x y-30 x+40 y+70]);
add_block('simulink/Signal Routing/From',[sys '/From ' tagHi], ...
          'Position',[x-70 y-30 x-10 y-10],'GotoTag',tagHi);
add_block('simulink/Signal Routing/From',[sys '/From ' tagLo], ...
          'Position',[x-70 y+50 x-10 y+70],'GotoTag',tagLo);

add_line(sys,['From ' tagHi '/1'],[satName '/1'],'autorouting','on');
add_line(sys,[nodeName '/1'],     [satName '/2'],'autorouting','on');
add_line(sys,['From ' tagLo '/1'],[satName '/3'],'autorouting','on');
for k = 1:size(dst,1)
    add_line(sys,[satName '/1'],sprintf('%s/%d',dst{k,1},dst{k,2}), ...
             'autorouting','on');
end
fprintf('  %s: limiter inserted, %d destination(s) re-fed\n', nodeName, size(dst,1));
end
