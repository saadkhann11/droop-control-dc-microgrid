function build_04_grid_breaker(mdl)
%PHASE4_ADD_BREAKER  Insert the point-of-common-coupling breaker.
%
%  A real three-phase breaker between the source and the transformer, not a
%  control-level "pretend the grid is gone" flag.  Islanding has to be a
%  PLANT event: the AFE must genuinely lose its stiff source, otherwise the
%  test proves nothing about whether the battery can actually hold the bus.
%
%  It opens at mg.t_island - the same parameter that drives the supervisor's
%  island flag - so the plant and the control can never disagree about which
%  mode the microgrid is in.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('powerlib');
pg  = [mdl '/PCC + Grid'];
brk = [pg '/Grid Breaker'];
src = [pg '/Three-Phase Source'];

if getSimulinkBlockHandle(brk) > 0
    set_param(brk,'SwitchTimes','mg.t_island');
    fprintf('build_04_grid_breaker: breaker already present, switching time refreshed\n');
    return
end

% record what the source currently feeds, phase by phase
sp  = get_param(src,'PortHandles').RConn;
dst = zeros(1,numel(sp));
for k = 1:numel(sp)
    lin = get_param(sp(k),'Line');
    assert(lin > 0, 'source phase %d is not connected', k);
    ports = [get_param(lin,'SrcPortHandle'), get_param(lin,'DstPortHandle')];
    ports = ports(ports ~= sp(k) & ports > 0);
    assert(~isempty(ports), 'could not find the far end of source phase %d', k);
    dst(k) = ports(1);
    delete_line(lin);
end

p = get_param(src,'Position');
add_block('powerlib/Elements/Three-Phase Breaker', brk, ...
          'Position',[p(3)+40 p(2) p(3)+110 p(4)], ...
          'InitialState','closed', ...
          'SwitchA','on','SwitchB','on','SwitchC','on', ...
          'SwitchTimes','mg.t_island', ...
          'External','off', ...
          'BreakerResistance','mg.Ron', ...
          'SnubberResistance','mg.Rsnub', ...
          'SnubberCapacitance','inf', ...
          'Measurements','None');

bl = get_param(brk,'PortHandles').LConn;
br = get_param(brk,'PortHandles').RConn;
for k = 1:3
    add_line(pg, sp(k),  bl(k));
    add_line(pg, br(k),  dst(k));
end

fprintf('build_04_grid_breaker: breaker inserted between the source and the transformer, opens at mg.t_island\n');
end
