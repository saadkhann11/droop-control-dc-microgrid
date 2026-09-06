function build_05_battery_pack(mdl)
%PHASE4_RESIZE_BATTERY  Make the pack able to island the park.
%
%  See the sizing note in microgridParams.m.  In short: Phase 4 is the first
%  phase in which the battery is the ONLY slack unit, and the original
%  250 V / 400 Ah lead-acid pack could not carry the park - it sagged under a
%  2.3C discharge until the 900 A limit opened the loop and the bus collapsed
%  to 648 V.
%
%  The Battery block derives its whole discharge curve (R, MaxQ, FullV,
%  nominal discharge current, exponential zone) from the chemistry, the
%  nominal voltage and the rated capacity.  Those derived values are stored as
%  LITERALS, so writing new numbers into mg is not enough - the block has to be
%  told, which is what re-writing NomV/NomQ below does: set_param fires the
%  block's own callback and it recomputes everything consistently.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
bb = [mdl '/Battery/Battery'];
mg = evalin('base','mg');

before = struct('R',get_param(bb,'R'),'MaxQ',get_param(bb,'MaxQ'), ...
                'FullV',get_param(bb,'FullV'),'Normal_OP',get_param(bb,'Normal_OP'));

set_param(bb,'BatType',mg.BatChemistry);
set_param(bb,'NomV','mg.Vbat_nom');      % re-writing forces the recompute
set_param(bb,'NomQ','mg.Qbat_Ah');

fprintf('build_05_battery_pack: %s, %g V / %g Ah (%.0f kWh)\n', ...
        get_param(bb,'BatType'), mg.Vbat_nom, mg.Qbat_Ah, mg.Vbat_nom*mg.Qbat_Ah/1000);
fprintf('  R          %-12s -> %s ohm\n',  before.R,         get_param(bb,'R'));
fprintf('  MaxQ       %-12s -> %s Ah\n',   before.MaxQ,      get_param(bb,'MaxQ'));
fprintf('  FullV      %-12s -> %s V\n',    before.FullV,     get_param(bb,'FullV'));
fprintf('  nominal I  %-12s -> %s A (%.2fC)\n', before.Normal_OP, get_param(bb,'Normal_OP'), ...
        str2double(get_param(bb,'Normal_OP'))/mg.Qbat_Ah);
fprintf('  island duty %.0f kW -> %.0f A = %.2fC ,  limit %.0f A\n', ...
        mg.Pbus_rated/1000, mg.Pbus_rated/mg.Vbat_nom, ...
        (mg.Pbus_rated/mg.Vbat_nom)/mg.Qbat_Ah, mg.Ibat_max);
end
