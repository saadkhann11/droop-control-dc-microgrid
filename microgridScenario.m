function microgridScenario(name, stopTime)
%MICROGRIDSCENARIO  Run and judge the operating cases a normal run cannot reach.
%
%   microgridScenario('list')              what is available
%   microgridScenario('soc90', 0.4)        battery above target - it supplies
%                                          the deficit before the grid does
%   microgridScenario('pvcurtail', 0.25)   battery full, PV in surplus - the PV
%                                          leaves MPPT and holds the bus itself
%   microgridScenario('overload', 0.5)     360 kW demanded of a 250 kW pack -
%                                          bays are shed until the bus recovers
%   microgridScenario('check')             judge whichever scenario last ran
%   microgridScenario('restore')           put every knob back
%
%  A scenario STARTS the simulation and returns immediately; the run continues
%  in the background.  Poll it with
%
%       get_param('microgrid','SimulationStatus')
%
%  and once that reads 'stopped', call microgridScenario('check').  You do not
%  have to name the scenario again - it is remembered.
%
%  ALWAYS finish with microgridScenario('restore'), or the next run silently
%  uses the last scenario's settings.
%
%  For an ordinary run of the model, this is the wrong file: use
%  microgridCheck('results') instead.

mdl   = 'microgrid';
GAIN  = [mdl '/PV + Boost/Irradiance/Solar Irradiance W//m2'];
KNOWN = {'soc90','pvcurtail','overload'};

if nargin < 1 || isempty(name), name = 'list'; end
if nargin < 2, stopTime = []; end
if ~bdIsLoaded(mdl), load_system(mdl); end

switch lower(name)
    case {'list','help','?'}
        fprintf('\n  scenarios:\n');
        fprintf('    soc90       0.4 s   battery above target - supplies before the grid\n');
        fprintf('    pvcurtail   0.25 s  battery full, PV in surplus - PV holds the bus\n');
        fprintf('    overload    0.5 s   demand beyond the pack - bays are shed\n');
        fprintf('\n  then:  microgridScenario(''check'')   and   microgridScenario(''restore'')\n\n');
        return

    case 'restore'
        set_param(GAIN,'Gain','150');
        evalin('base','microgridParams;');
        if isappdata(0,'mgLastScenario'), rmappdata(0,'mgLastScenario'); end
        fprintf('microgridScenario: knobs restored from microgridParams.m\n');
        return

    case 'check'
        if ~isappdata(0,'mgLastScenario')
            error('microgridScenario:noneRun', ...
                  ['no scenario has been run in this session.\n' ...
                   '  for an ordinary run of the model, use microgridCheck(''results'')']);
        end
        verdict(getappdata(0,'mgLastScenario'));
        return
end

if ~ismember(lower(name), KNOWN)
    error('microgridScenario:unknown', ...
          ['"%s" is not a scenario.\n  available: %s\n' ...
           '  for an ordinary run of the model, use microgridCheck(''results'')'], ...
          name, strjoin(KNOWN, ', '));
end

defaults = struct('soc90',0.4,'pvcurtail',0.25,'overload',0.5);
if isempty(stopTime), stopTime = defaults.(lower(name)); end
mg = evalin('base','mg');

switch lower(name)
    case 'soc90'
        %  Grid-connected throughout.  SOC starts above target, so the
        %  supervisor should release the battery, bias its set-point ABOVE the
        %  grid's, and the battery should then carry more of the load.
        mg.SOC0        = 90;
        mg.t_island    = 10;        % past the stop time: never islands
        mg.t_reconnect = 11;
        set_param(GAIN,'Gain','150');

    case 'pvcurtail'
        %  Islanded almost immediately, battery already full so it cannot
        %  absorb, PV at full sun into an idle park.  The only way to keep the
        %  bus off the dump resistor is for the PV to hold 850 V itself.
        mg.SOC0        = 100;
        mg.t_island    = 0.05;
        mg.t_reconnect = 10;
        set_param(GAIN,'Gain','1000');

    case 'overload'
        %  The battery is sized for the park; it is not sized for the park plus
        %  a fault.  Every bay at mg.Poverload_bay together exceeds its rating,
        %  so the only way to hold the bus is to drop load.
        mg.SOC0        = 60;
        mg.t_island    = 0.20;      % island early, at full load
        mg.t_reconnect = 10;        % and stay islanded
        mg.evSessions  = struct( ...
            'tArrive', {0.05, 0.08, 0.11, 0.14}, ...
            'tTaper',  {inf,  inf,  inf,  inf }, ...
            'tDepart', {inf,  inf,  inf,  inf }, ...
            'fracEnd', {1,    1,    1,    1   });
        mg.evLoad = evLoadProfile(mg.evSessions, mg.Vbus_nom, mg.Rload_idle, ...
                                  stopTime, mg.Poverload_bay);
        set_param(GAIN,'Gain','150');
end

assignin('base','mg',mg);
setappdata(0,'mgLastScenario',lower(name));
set_param(mdl,'StopTime',num2str(stopTime));
fprintf(['microgridScenario "%s": SOC0=%g %%, t_island=%g s, irradiance=%s W/m2, ' ...
         'stop=%g s\n'], name, mg.SOC0, mg.t_island, get_param(GAIN,'Gain'), stopTime);
fprintf(['  started in the background - poll SimulationStatus, then call ' ...
         'microgridScenario(''check'')\n']);
set_param(mdl,'SimulationCommand','start');
end

%% ======================================================================
%  verdicts
%% ======================================================================
function verdict(name)
mg = evalin('base','mg');
Ts = 5e-6;
if ~evalin('base','exist(''Vdc'',''var'')')
    error('microgridScenario:noData', ...
          'no simulation results in the workspace - has the run finished?');
end
V  = evalin('base','Vdc'); V = V(:);
t  = (0:numel(V)-1)'*Ts; Te = t(end);
g  = @(x) interp1(linspace(0,Te,numel(x))', x(:), t, 'previous','extrap');
sig = @(n) sigval(n, t, Te);

fprintf('\n--- SCENARIO "%s" ---------------------------------------------\n', name);
pass = 0; fail = 0;

switch lower(name)

    case 'soc90'
        IL   = g(evalin('base','ILbat'));
        Igr  = g(evalin('base','Igrid_ref'));
        V0b  = sig('V0bat');
        Ihi  = sig('Ibat_hi');
        w    = t > 0.30;                       % after the second load step

        [pass,fail] = tally(pass,fail,'Battery released above target SOC', ...
            all(abs(Ihi(t>0.05) - mg.Ibat_max) < 1e-6), ...
            sprintf('Ibat_hi = %.0f A (rating %.0f A)', median(Ihi(t>0.05)), mg.Ibat_max));

        want = mg.Vbus_nom - mg.k_soc*(mg.SOC_target - mg.SOC0);
        [pass,fail] = tally(pass,fail,'Battery set-point biased ABOVE the grid''s', ...
            median(V0b(t>0.05)) > mg.V0_grid + 1 && abs(median(V0b(t>0.05)) - want) < 0.5, ...
            sprintf('V0bat = %.1f V vs V0grid = %.1f V (expected %.1f)', ...
                    median(V0b(t>0.05)), mg.V0_grid, want));

        [pass,fail] = tally(pass,fail,'Battery discharges instead of charging', ...
            mean(IL(w)) > 0, sprintf('mean battery current %+.0f A', mean(IL(w))));

        Pbat  = mean(IL(w)) * mg.Vbat_nom / 1000;
        Pgrid = mean(Igr(w)) * mg.Vbus_nom / 1000;
        [pass,fail] = tally(pass,fail,'Battery carries more of the load than the grid', ...
            Pbat > Pgrid, sprintf('battery %.0f kW vs grid %.0f kW', Pbat, Pgrid));

        [pass,fail] = tally(pass,fail,'Bus stays inside the droop band', ...
            min(V(t>0.02)) > mg.Vbus_min && max(V(t>0.02)) < mg.Vbus_max, ...
            sprintf('%.0f .. %.0f V', min(V(t>0.02)), max(V(t>0.02))));

    case 'pvcurtail'
        pvm = sig('pvMode');
        en2 = sig('pvEnVctrl');
        Ilo = sig('Ibat_lo');
        w   = t > mg.t_island + 0.05;

        [pass,fail] = tally(pass,fail,'Full battery may not charge', ...
            all(abs(Ilo(t>0.02)) < 1e-6), sprintf('Ibat_lo = %.1f A', median(Ilo(t>0.02))));

        [pass,fail] = tally(pass,fail,'PV left MPPT for voltage control', ...
            any(pvm < 0.5), sprintf('voltage control active %.0f%% of the run', 100*mean(en2)));

        if any(pvm < 0.5)
            k = find(pvm < 0.5, 1);
            [pass,fail] = tally(pass,fail,'Handover happened at the 850 V threshold', ...
                abs(V(k) - mg.Vpv_ctrl_on) < 15, ...
                sprintf('bus was %.0f V when the PV took over (threshold %.0f V)', V(k), mg.Vpv_ctrl_on));
            Vc = V(w & (pvm < 0.5));
            if ~isempty(Vc)
                [pass,fail] = tally(pass,fail,'PV holds the bus at its set-point', ...
                    abs(median(Vc) - mg.Vpv_ctrl_ref) < 15, ...
                    sprintf('bus held at %.0f V (target %.0f V)', median(Vc), mg.Vpv_ctrl_ref));
            end
        end

        [pass,fail] = tally(pass,fail,'PV curtailed before the dump resistor fired', ...
            max(V) < mg.Vdrain_on, ...
            sprintf('bus peak %.0f V vs dump threshold %.0f V', max(V), mg.Vdrain_on));

        nsw = sum(diff(pvm > 0.5) ~= 0);
        [pass,fail] = tally(pass,fail,'Handover does not limit-cycle', ...
            nsw <= 2, sprintf('%d mode transition(s)', nsw));

    case 'overload'
        shed = sig('shedLevel');
        IL   = g(evalin('base','ILbat'));
        w    = t > mg.t_island + 0.05;

        [pass,fail] = tally(pass,fail,'Shedding fires when demand exceeds the pack', ...
            max(shed) > 0, sprintf('%d of 4 bays shed at the worst point', max(shed)));
        [pass,fail] = tally(pass,fail,'Bus held up instead of collapsing', ...
            min(V(w)) > 650, sprintf('islanded bus low point %.0f V', min(V(w))));
        [pass,fail] = tally(pass,fail,'Bus recovers into the band after shedding', ...
            median(V(t > Te-0.05)) > mg.Vbus_min, ...
            sprintf('bus at end of run %.0f V (band floor %.0f V)', ...
                    median(V(t > Te-0.05)), mg.Vbus_min));
        [pass,fail] = tally(pass,fail,'Battery stays within its rating throughout', ...
            max(abs(IL)) <= mg.Ibat_max*1.05, ...
            sprintf('|I|max %.0f A (limit %.0f A)', max(abs(IL)), mg.Ibat_max));
        nflip = sum(diff(shed) ~= 0);
        [pass,fail] = tally(pass,fail,'Shedding does not chatter', ...
            nflip <= 8, sprintf('%d stage change(s) over the run', nflip));
        [pass,fail] = tally(pass,fail,'Nothing shed before the island', ...
            all(shed(t < mg.t_island) == 0), 'grid-connected operation untouched');
end

fprintf('---------------------------------------------------------------\n');
if fail == 0
    fprintf('  SCENARIO "%s": ALL %d CHECKS PASSED\n', name, pass);
else
    fprintf('  SCENARIO "%s": %d of %d CHECKS FAILED\n', name, fail, pass+fail);
end
fprintf('---------------------------------------------------------------\n\n');
end

function y = sigval(nm, t, Te)
s = evalin('base', nm);
if isstruct(s) && isfield(s,'time')
    y = interp1(s.time(:), s.signals.values(:), t, 'previous','extrap');
else
    y = interp1(linspace(0,Te,numel(s))', s(:), t, 'previous','extrap');
end
end

function [p,f] = tally(p,f,name,ok,detail)
if ok, s='PASS'; p=p+1; else, s='FAIL'; f=f+1; end
fprintf('  [%s]  %-50s %s\n', s, name, detail);
end
