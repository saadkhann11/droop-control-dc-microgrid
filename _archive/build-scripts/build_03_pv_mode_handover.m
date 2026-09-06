function build_03_pv_mode_handover(mdl)
%PHASE4_WIRE_PVMODE  Make the PV MPPT / voltage-control handover automatic.
%
%  microgrid/PV + Boost/PV Control/PV Mode contains two Switch blocks
%  that enable the MPPT branch and the constant-voltage branch.  Both take
%  their selector from ONE constant, 'PV Mode', which was hard-wired to 1 -
%  MPPT forever, voltage control unreachable.  Phase 4 replaces that constant
%  with the supervisor's pvMode signal:
%
%       pvMode = 1  ->  MPPT           (Switch passes u1 = enable MPPT)
%       pvMode = 0  ->  voltage control(Switch passes u3 = enable Vctrl)
%
%  Nothing else in the PV controller changes.  The voltage-control branch was
%  already complete and already regulating the BOOST OUTPUT (= the DC bus) to
%  the Vref inport, which the top-level Vpv_ctrl_ref constant holds at 850 V.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');
NL = char(10);
pm = [mdl '/PV + Boost/PV Control/PV Mode'];
sel = [pm '/PV Mode'];

% The dashboard's 'Slider Switch' was bound to the constant we just removed,
% so it now points at nothing.  It was the MANUAL mode selector, and the whole
% point of Phase 4 is that the handover is automatic - a hand switch on it
% would be a way to defeat the protection it implements.  Remove it rather
% than leave a dead control on the dashboard.
slider = [mdl '/PV + Boost/Slider Switch'];
if getSimulinkBlockHandle(slider) > 0
    delete_block(slider);
    fprintf('build_03_pv_mode_handover: removed the now-orphaned manual PV mode slider\n');
end

if strcmp(get_param(sel,'BlockType'),'From')
    set_param(sel,'GotoTag','pvMode');
    fprintf('build_03_pv_mode_handover: selector already a From block, tag refreshed\n');
    return
end

% remember where the selector fed, then swap the block underneath it
tgt = {};
ph = get_param(sel,'PortHandles');
lin = get_param(ph.Outport(1),'Line');
assert(lin > 0, 'PV Mode selector constant is not connected');
dstB = get_param(lin,'DstBlockHandle');
dstP = get_param(lin,'DstPortHandle');
for k = 1:numel(dstB)
    if dstB(k) > 0
        pn = get_param(dstP(k),'PortNumber');
        if ischar(pn), pn = str2double(pn); end
        tgt(end+1,:) = {get_param(dstB(k),'Name'), pn};  %#ok<AGROW>
    end
end
pos = get_param(sel,'Position');
delete_line(lin);
delete_block(sel);

add_block('simulink/Signal Routing/From', sel, ...
          'Position',[pos(1)-20 pos(2) pos(3)+20 pos(4)], 'GotoTag','pvMode');
for k = 1:size(tgt,1)
    add_line(pm, 'PV Mode/1', sprintf('%s/%d',tgt{k,1},tgt{k,2}), 'autorouting','on');
end

% log the branch enables so the handover can be checked after a run
addLog(pm, 'MPPT',     'pvEnMPPT', [ 520  60]);
addLog(pm, 'VoltCtrl', 'pvEnVctrl',[ 520 160]);

fprintf('build_03_pv_mode_handover: selector is now the supervisor''s pvMode signal (%d switch inputs)\n', size(tgt,1));
end

% -------------------------------------------------------------------------
function addLog(sys, srcName, varName, xy)
%ADDLOG  Tap an existing signal with a To Workspace block.
nm = [sys '/log ' varName];
if getSimulinkBlockHandle(nm) > 0, return; end
add_block('simulink/Sinks/To Workspace', nm, ...
          'Position',[xy(1) xy(2) xy(1)+80 xy(2)+30], ...
          'VariableName',varName,'SaveFormat','StructureWithTime','SampleTime','-1', ...
          'MaxDataPoints','inf','Decimation','20');
% the source is an Outport block, so tap what feeds it
src = [sys '/' srcName];
lin = get_param(get_param(src,'PortHandles').Inport(1),'Line');
if lin > 0
    sb = get_param(lin,'SrcBlockHandle');
    sp = get_param(lin,'SrcPortHandle');
    pn = get_param(sp,'PortNumber');
    if ischar(pn), pn = str2double(pn); end
    add_line(sys, sprintf('%s/%d',get_param(sb,'Name'),pn), ['log ' varName '/1'], ...
             'autorouting','on');
end
end
