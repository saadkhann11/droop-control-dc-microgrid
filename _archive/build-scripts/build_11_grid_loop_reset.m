function build_11_grid_loop_reset(mdl)
%PHASE5_AFE_RESET  Hold the AFE's integrators in reset while its gates are off.
%
%  In the first Phase 4 islanded run the AFE's outer voltage loop sat with its
%  output pinned at the 255 A id limit for 300 ms, trying to recharge a DC link
%  from a grid that was not there.  Phase 4 stopped that mattering by blocking
%  the gates - the converter could no longer act on the wound-up command.  It
%  did not stop the winding up, which is fine as long as nobody ever closes
%  the breaker again.  Phase 5 closes the breaker again.
%
%  All three loops are stock Simulink PID Controller blocks, which have an
%  external reset built in, so this needs no surgery: ExternalReset = 'level'
%  holds each integrator at its initial condition for as long as the reset
%  input is non-zero.  The reset input is the supervisor's afeReset, which is
%  high for exactly as long as gridEnable is low - the island plus the
%  resynchronisation window.  The loops therefore come out of reset at the
%  same instant the gates are released, starting from zero rather than from
%  wherever the island left them.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');
GC = [mdl '/PCC + Grid/Grid Converter Control'];
pis = {'PI Vlink','PI id','PI iq'};

if getSimulinkBlockHandle([GC '/From afeReset']) <= 0
    add_block('simulink/Signal Routing/From',[GC '/From afeReset'], ...
              'Position',[60 40 150 60],'GotoTag','afeReset');
end
src = get_param([GC '/From afeReset'],'PortHandles').Outport(1);

n = 0;
for k = 1:numel(pis)
    b = [GC '/' pis{k}];
    if strcmp(get_param(b,'ExternalReset'),'level'), continue; end
    set_param(b,'ExternalReset','level');
    ph = get_param(b,'PortHandles');
    % the reset port is the last inport the PID block exposes
    rp = ph.Inport(end);
    if get_param(rp,'Line') <= 0
        add_line(GC, src, rp, 'autorouting','on');
    end
    n = n + 1;
end
fprintf('build_11_grid_loop_reset: %d AFE loop(s) now reset by afeReset while gated off\n', n);
end
