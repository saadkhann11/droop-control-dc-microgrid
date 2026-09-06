function build_12_reconnection(mdl)
%PHASE5_RECONNECT_BREAKER  Give the breaker a reclose time.
%
%  Phase 4 gave the Three-Phase Breaker a single switching time.  It now gets
%  two, so the plant performs the whole cycle - open at mg.t_island, close at
%  mg.t_reconnect - and still shares its timing with the supervisor rather
%  than duplicating it.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
brk = [mdl '/PCC + Grid/Grid Breaker'];
set_param(brk,'SwitchTimes','[mg.t_island mg.t_reconnect]');
fprintf('build_12_reconnection: SwitchTimes = %s\n', get_param(brk,'SwitchTimes'));
end
