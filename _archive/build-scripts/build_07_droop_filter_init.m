function build_07_droop_filter_init(mdl)
%PHASE5_FIX_DROOP_INIT  Give the droop node's measurement filter an initial
%                       condition, and remove the start-up overshoot with it.
%
%  THE BUG.  microgridLib/DC Droop Node filtered the bus voltage with a
%  Transfer Fcn, [1]/[Tf 1].  A Transfer Fcn has no initial condition - it
%  starts at ZERO.  So for the first few milliseconds of every run each droop
%  node believed the bus was at 0 V while its set-point said 800 V, computed
%
%        Iref = (800 - 0)/R  =  25 000 A
%
%  and sat hard against its limit.  Both converters slammed full current into
%  a bus that was already at 800 V, which is where the ~819 V overshoot in the
%  first 20 ms came from.  Every regression check has been skipping that
%  window since Phase 1.
%
%  This is the same fault Phase 1 fixed on the Voltage-Current Simscape
%  Interface (v0 = 0 -> a 16 kA first-sample spike) and Phase 4 avoided in the
%  supervisor's own bus filter.  A measurement filter that starts at zero
%  tells the controller the plant is dead.
%
%  THE FIX.  The same construction used in the supervisor: a first-order lag
%  built from an integrator, so it HAS an initial condition.
%
%        y' = (Vbus - y)/Tf ,   y(0) = Vinit
%
%  Vinit becomes a sixth mask parameter, set to mg.Vbus_nom on both instances.
%  Behaviour after the first few Tf is identical to the Transfer Fcn - this
%  changes only where the filter starts, not what it does.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
lib  = 'microgridLib';
node = [lib '/DC Droop Node'];

load_system(lib);
load_system('simulink');
wasLocked = strcmp(get_param(lib,'Lock'),'on');
set_param(lib,'Lock','off');

if strcmp(get_param([node '/Meas filter'],'BlockType'),'TransferFcn')
    % --- swap the filter -------------------------------------------------
    pos = get_param([node '/Meas filter'],'Position');
    delete_line(node,'Vbus/1','Meas filter/1');
    delete_line(node,'Meas filter/1','dV/2');
    delete_block([node '/Meas filter']);

    x = pos(1); y = pos(2);
    add_block('simulink/Math Operations/Sum',[node '/filt err'], ...
              'Position',[x-70 y-5 x-50 y+35],'Inputs','+-');
    add_block('simulink/Math Operations/Gain',[node '/1//Tf'], ...
              'Position',[x-35 y-3 x-5 y+33],'Gain','1/Tf');
    add_block('simulink/Continuous/Integrator',[node '/Meas filter'], ...
              'Position',[x y-5 x+30 y+35],'InitialCondition','Vinit');

    add_line(node,'Vbus/1',     'filt err/1',   'autorouting','on');
    add_line(node,'filt err/1', '1//Tf/1',      'autorouting','on');
    add_line(node,'1//Tf/1',    'Meas filter/1','autorouting','on');
    add_line(node,'Meas filter/1','dV/2',       'autorouting','on');
    add_line(node,'Meas filter/1','filt err/2', 'autorouting','on');
    fprintf('build_07_droop_filter_init: %s filter replaced with an initialised lag\n', node);
end

% --- extend the mask -----------------------------------------------------
%  Through the Mask API rather than by writing MaskVariables/MaskPrompts/
%  MaskValues by hand: those three have to stay index-aligned, and set_param
%  rejects the intermediate states you pass through while editing them
%  separately.
m = Simulink.Mask.get(node);
if isempty(m.getParameter('Vinit'))
    m.addParameter('Type','edit', ...
                   'Prompt','Filter initial value  [V]', ...
                   'Name','Vinit', ...
                   'Value','800');
    fprintf('build_07_droop_filter_init: mask parameter Vinit added\n');
else
    v = m.getParameter('Vinit');
    v.Prompt = 'Filter initial value  [V]';
    if isempty(v.Value), v.Value = '800'; end
end
% drop anything a half-finished edit may have left behind
for q = numel(m.Parameters):-1:1
    if startsWith(m.Parameters(q).Name,'Parameter')
        m.removeParameter(m.Parameters(q).Name);
    end
end

save_system(lib);
if wasLocked, set_param(lib,'Lock','on'); end

% --- point both instances at the nominal bus ------------------------------
if ~bdIsLoaded(mdl), load_system(mdl); end
inst = find_system(mdl,'LookUnderMasks','all','FollowLinks','off', ...
                   'RegExp','on','ReferenceBlock','microgridLib/DC Droop Node');
for k = 1:numel(inst)
    try
        set_param(inst{k},'LinkStatus','restore');   % pick up the new mask
    catch
    end
    set_param(inst{k},'Vinit','mg.Vbus_nom');
    fprintf('  %s : Vinit = %s\n', strrep(inst{k},char(10),' '), get_param(inst{k},'Vinit'));
end
end
