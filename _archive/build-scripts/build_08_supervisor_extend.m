function build_08_supervisor_extend(mdl)
%PHASE5_EXTEND_SUPERVISOR  Add reconnection and load shedding to the Phase 4
%                          supervisor.
%
%  RUN THIS AFTER build_01_supervisor - that script deletes and rebuilds
%  the whole Supervisor subsystem, so it has to go first.  Everything stays in
%  ONE Supervisor rather than being split into a second policy block: the whole
%  point of Phase 4 was that the policy can be read off a single diagram.
%
%  ---- 1. islanding becomes a WINDOW, not a step -------------------------
%
%  Phase 4 had one flag doing two jobs.  They are different jobs and they turn
%  on and off at different times, so Phase 5 separates them:
%
%     island      is the BREAKER open?   step(t_island) - step(t_reconnect)
%     gridEnable  may the CONVERTER act? 1 - step(t_island) + step(t_release)
%
%  where t_release = t_reconnect + t_resync.  Between t_reconnect and
%  t_release the breaker is closed but the converter is still gated off and
%  its integrators still held in reset - that gap IS the resynchronisation.
%  Closing the breaker and releasing the gates at the same instant throws a
%  wound-up converter at a live grid, which is how a real AFE trips.
%
%  Everything downstream already keys off these two signals, so the grid droop
%  limits stay clamped through the resync window without any extra wiring:
%  they were wired to gridEnable in Phase 4, not to island.
%
%  ---- 2. load shedding ---------------------------------------------------
%
%  Four hysteretic thresholds on the bus voltage, one per bay, dropped in
%  reverse priority - bay 4 first, bay 1 last.  Stated as
%
%      SHED below the droop band ,  RESTORE inside it.
%
%  so nothing can shed on a load step or on the islanding transient.  It is
%  armed in BOTH modes on purpose: it is a protection, not a mode behaviour.
%  Grid-connected it simply never fires, because the grid holds the bus up.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');
sup = [mdl '/Supervisor'];
A = @(lib,nm,pos,varargin) add_block(['simulink/' lib], [sup '/' nm], ...
                                     'Position', pos, varargin{:});

%% ---- 1. reconnection ---------------------------------------------------
if getSimulinkBlockHandle([sup '/Island window']) <= 0
    A('Sources/Step','Reclose',[ 30 220  90 250], ...
       'Time','mg.t_reconnect','Before','0','After','1','SampleTime','0');
    A('Sources/Step','Release',[ 30 640  90 670], ...
       'Time','mg.t_reconnect+mg.t_resync','Before','0','After','1','SampleTime','0');
    A('Math Operations/Sum','Island window',[140 220 160 260],'Inputs','+-');

    %  everything that means "the breaker is open" moves onto the window;
    %  Grid enable keeps reading the raw Island step, because the converter
    %  must go down the instant the breaker opens and come back later
    moveIslandConsumers(sup);

    add_line(sup,'Island/1','Island window/1','autorouting','on');
    add_line(sup,'Reclose/1','Island window/2','autorouting','on');
    reconnect(sup,'Island window', ...
              {'Sel V0bat',2; 'Any allows',1; 'Goto island',1; 'log island',1});

    %  gridEnable = 1 - Island + Release
    set_param([sup '/Grid enable'],'Inputs','+-+');
    add_line(sup, get_param([sup '/Release'],'PortHandles').Outport(1), ...
                  get_param([sup '/Grid enable'],'PortHandles').Inport(3), ...
                  'autorouting','on');

    %  the AFE's integrators are held in reset for exactly as long as its
    %  gates are blocked, so they start from zero and not from their limits
    A('Math Operations/Sum','AFE reset',[350 700 370 740],'Inputs','+-');
    A('Sources/Constant','one2',[260 690 310 710],'Value','1');
    A('Signal Routing/Goto','Goto afeReset',[430 705 520 725], ...
       'GotoTag','afeReset','TagVisibility','global');
    add_line(sup,'one2/1','AFE reset/1','autorouting','on');
    add_line(sup,'Grid enable/1','AFE reset/2','autorouting','on');
    add_line(sup,'AFE reset/1','Goto afeReset/1','autorouting','on');
    fprintf('build_08_supervisor_extend: island is now a window; gridEnable and afeReset added\n');
end

%% ---- 2. load shedding --------------------------------------------------
if getSimulinkBlockHandle([sup '/Shed 4']) <= 0
    %  the relays watch -Vbus, because a Relay turns ON above its threshold
    %  and shedding is a BELOW test; 'neg Vbus' already exists from Phase 4
    y = 1120;
    for k = 4:-1:1
        nm = sprintf('Shed %d', k);
        A('Discontinuities/Relay', nm, [270 y 340 y+50], ...
           'OnSwitchValue',  sprintf('-mg.Vshed(%d)', 5-k), ...
           'OffSwitchValue', sprintf('-mg.Vshed_rst(%d)', 5-k), ...
           'OnOutputValue','1','OffOutputValue','0');
        A('Signal Routing/Goto', sprintf('Goto shed%d',k), [430 y+15 520 y+35], ...
           'GotoTag', sprintf('shed%d',k), 'TagVisibility','global');
        add_line(sup,'neg Vbus/1',[nm '/1'],'autorouting','on');
        add_line(sup,[nm '/1'],sprintf('Goto shed%d/1',k),'autorouting','on');
        y = y + 70;
    end

    %  one number that says how much of the park is off, for the log
    A('Math Operations/Sum','Shed level',[570 1160 590 1300],'Inputs','++++');
    A('Sinks/To Workspace','log shedLevel',[630 1210 720 1240], ...
       'VariableName','shedLevel','SaveFormat','StructureWithTime', ...
       'SampleTime','-1','MaxDataPoints','inf','Decimation','20');
    for k = 1:4
        add_line(sup,sprintf('Shed %d/1',k),sprintf('Shed level/%d',k),'autorouting','on');
    end
    add_line(sup,'Shed level/1','log shedLevel/1','autorouting','on');
    fprintf('build_08_supervisor_extend: 4-stage hysteretic load shedding added\n');
end
end

% -------------------------------------------------------------------------
function moveIslandConsumers(sup)
%MOVEISLANDCONSUMERS  Drop the lines from the raw Island step to everything
%  that means "islanded", keeping Grid enable attached.
lin = get_param(get_param([sup '/Island'],'PortHandles').Outport(1),'Line');
if lin <= 0, return; end
delete_line(lin);
add_line(sup,'Island/1','Grid enable/2','autorouting','on');
end

function reconnect(sup, srcName, dst)
for k = 1:size(dst,1)
    add_line(sup, sprintf('%s/1',srcName), sprintf('%s/%d',dst{k,1},dst{k,2}), ...
             'autorouting','on');
end
end
