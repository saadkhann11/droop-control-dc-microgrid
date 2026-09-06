%% microgridParams  -  system-level parameters for microgrid.slx
%
% Everything that is NOT part of the PV array / MPPT boost design lives here.
% The PV string, boost converter and MPPT controller parameters stay in
% SolarPVMPPTBoostData.mlx, which is run first by the model's PreLoadFcn.
%
% All values are collected in the struct  mg  so they are easy to find,
% easy to sweep, and impossible to confuse with the PV data structs.
%
% Created to replace hard-coded literals that were buried inside blocks.

%  Start from an empty struct.  Without this the script MERGES into whatever
%  mg is already in the workspace, so a field deleted from this file - or one
%  a scenario script set - survives silently and the model keeps running on a
%  parameter nobody can find any more.
clear mg
mg = struct();
%% ------------------------------------------------------------------------
%  DC bus
%  ------------------------------------------------------------------------
mg.Vbus_nom      = 800;        % V   nominal DC bus voltage (= dcVoltage.avgDCVoltage)
mg.Vbus_max      = 840;        % V   upper end of the normal operating band
mg.Vbus_min      = 760;        % V   lower end of the normal operating band
mg.Pbus_rated    = 200e3;      % W   design power level of the whole park

%% ------------------------------------------------------------------------
%  Bus voltage thresholds  -  ORDER MATTERS
%  ------------------------------------------------------------------------
%  Normal droop band ......... 760 - 840 V   converters share the load
%  PV curtailment ............ 850 V         PV leaves MPPT, holds the bus
%  Dump resistor ............. 870 V         last resort, burns the surplus
%
%  The drain must sit ABOVE the PV curtailment threshold, otherwise the
%  resistor fires before the PV has a chance to back off and the park
%  wastes energy it could simply have stopped producing.
mg.Vpv_ctrl_ref  = 850;        % V   PV voltage-control target
mg.Vdrain_on     = 870;        % V   dump resistor switches IN
mg.Vdrain_off    = 845;        % V   dump resistor switches OUT (hysteresis)

%% ------------------------------------------------------------------------
%  Dump resistor ("Drain")
%  ------------------------------------------------------------------------
mg.Pdrain_rated  = mg.Pbus_rated;                    % W  must absorb full PV output
mg.Rdrain        = mg.Vdrain_on^2/mg.Pdrain_rated;   % ohm  ~3.78
mg.Rdrain_on     = 1e-3;       % ohm  switch on-state resistance

%% ------------------------------------------------------------------------
%  Battery
%  ------------------------------------------------------------------------
%  PACK SIZING - set by the ISLAND duty, not by the energy target
%  ------------------------------------------------------------------------
%  Phases 1-3 never asked the battery to carry the park on its own: the grid
%  was always there to share.  Islanding removes the grid, and the battery
%  becomes the only slack unit - it must then deliver mg.Pbus_rated by itself.
%
%  The original pack (250 V / 400 Ah lead-acid, 100 kWh) could not.  Serving
%  the fully loaded park islanded needs ~192 kW, which from that pack is 2.3C
%  against a block nominal discharge current of 124 A (0.31C).  Measured in
%  the first islanded run: terminal voltage sagged 244 -> 214 V under load,
%  the droop then demanded more current to make up the lost power, which sagged
%  it further, and at the 900 A limit the loop opened and the bus collapsed
%  from 783 V to 648 V.  A current limit the plant cannot honour is not a
%  limit, it is a cliff.
%
%  Lead-acid is also simply the wrong device for a charging park's buffer:
%  it is a 0.3C chemistry being asked for 2C.  Li-ion is what these
%  installations use.
%
%  Sized so the island duty is under 1C:
%       240 kWh at 400 V ,  200 kW island load  ->  500 A  =  0.83C
mg.Vbat_nom      = 400;        % V   nominal battery voltage  (was 250)
mg.Qbat_Ah       = 600;        % Ah  240 kWh                  (was 400)
mg.Ebat_kWh      = mg.Vbat_nom*mg.Qbat_Ah/1000;      % kWh  informational
mg.SOC0          = 30;         % %   initial state of charge
mg.SOC_target    = 80;         % %   grid-connected target SOC
mg.SOC_max       = 100;        % %   island-mode charge ceiling

%% ------------------------------------------------------------------------
%  Battery bidirectional DC/DC converter
%  ------------------------------------------------------------------------
mg.fsw_bat       = 10e3;       % Hz  switching frequency
% Current limit derived from a power rating, not chosen as a round number, so
% it stays consistent with the pack whenever the pack is resized.  25 % of
% headroom over the park rating covers the losses and the transient the
% battery has to absorb the instant the breaker opens.
mg.Pbat_rated    = 1.25*mg.Pbus_rated;               % W   250 kW
mg.Ibat_max      = mg.Pbat_rated/mg.Vbat_nom;        % A   625, = 1.04C
% Inductor sized for ~10% current ripple at the 250 V / 800 V operating point:
%   D = 400/800 = 0.5 ,  dI = Vbat*D/(L*fsw) = 40 A, 6 % of the 625 A rating
mg.Lbat          = 0.5e-3;     % H
mg.Rbat_L        = 5e-3;       % ohm  realistic copper resistance (was 1 ohm)
mg.BatChemistry  = 'Lithium-Ion';   % see the pack sizing note above
mg.Cbat          = 1e-3;       % F    battery-side capacitor
mg.Cbat_bus      = 1200e-6;    % F    bus-side capacitor
mg.Vbat_C0       = mg.Vbat_nom;% V    battery-side capacitor initial voltage

% Inner current-loop gains for the battery DC/DC, matched to the inductor:
%   d(i)/dt = (D*Vbus - Vbat)/Lbat   with D the duty of the UPPER switch S1.
% Internal model control:  Kp = Lbat*wc/Vbus , zero placed at Rbat_L/Lbat.
mg.wc_i_bat      = 2*pi*1000;                        % rad/s
mg.Kp_i_bat      = mg.Lbat*mg.wc_i_bat/mg.Vbus_nom;  % duty per A
mg.Ki_i_bat      = mg.Kp_i_bat*mg.Rbat_L/mg.Lbat;

% Outer bus-voltage loop of the battery converter.  Kept at the values the
% model was built with; a droop law later replaced this loop.
mg.Kp_v_bat      = 0.65;       % A/V
mg.Ki_v_bat      = 150;        % A/(V*s)

% Duty limits and feed-forward guards for the battery converter.
% The nominal duty of the upper switch is Vbat/Vbus; the current loop only
% trims around it, so the trim is deliberately bounded well short of the rail.
mg.Dbat_nom      = mg.Vbat_nom/mg.Vbus_nom;          % ~0.3125
mg.Dbat_trim     = 0.30;       % max duty correction from the current loop
mg.Dbat_min      = 0.05;
mg.Dbat_max      = 0.95;
mg.Vbat_ff_min   = 0.5*mg.Vbat_nom;   % V  floor on the measured battery voltage
mg.Vbus_ff_min   = 0.5*mg.Vbus_nom;   % V  floor on the measured bus voltage

%% ------------------------------------------------------------------------
%  Grid connection  -  source and transformer
%  ------------------------------------------------------------------------
mg.Vgrid_LL      = 25e3;       % V   medium-voltage grid, line-line rms
mg.fgrid         = 50;         % Hz
mg.wgrid         = 2*pi*mg.fgrid;                    % rad/s
mg.Vsec_LL       = 800;        % V   transformer secondary, line-line rms
mg.Strafo        = 800e3;      % VA  transformer rating
mg.Vph_peak      = mg.Vsec_LL*sqrt(2)/sqrt(3);       % V  ~653, phase peak at the AFE

%% ------------------------------------------------------------------------
%  Active front end (AC/DC), 2-level IGBT bridge
%  ------------------------------------------------------------------------
%  A 2-level VSC is a BOOST-type rectifier: its DC link must sit above the
%  peak of the AC line-line voltage, sqrt(2)*800 = 1131 V, or it degenerates
%  into an uncontrolled diode bridge.  With plain SPWM the reachable phase
%  peak is Vlink/2, so 1131 V would leave no modulation margin at all.
%  1600 V gives a modulation index of ~653/800 = 0.82 at rated voltage,
%  and makes the downstream DC/DC duty a convenient 800/1600 = 0.5.
mg.Vlink_ref     = 1600;       % V   AFE DC link setpoint
mg.Clink         = 4.7e-3;     % F   DC link capacitor
mg.fsw_afe       = 5e3;        % Hz  AFE switching frequency
mg.Sgrid_rated   = 250e3;      % VA  grid converter rating

% Line reactor between transformer and bridge, ~0.1 pu on the converter base:
%   Zbase = Vsec^2/S = 800^2/200e3 = 3.2 ohm  ->  0.32 ohm  ->  1 mH at 50 Hz
mg.Lgrid         = 1e-3;       % H
mg.Rgrid         = 10e-3;      % ohm

% Peak phase current at the converter rating
mg.Id_max        = sqrt(2)*mg.Sgrid_rated/(sqrt(3)*mg.Vsec_LL);   % A  ~255

% Inner current loop, internal model control:  Kp = L*wc , Ki = R*wc
% Bandwidth chosen at ~1/10 of the switching frequency.
mg.wc_i_afe      = 2*pi*mg.fsw_afe/10;               % rad/s  ~3140
mg.Kp_i_afe      = mg.Lgrid*mg.wc_i_afe;             % V/A
mg.Ki_i_afe      = mg.Rgrid*mg.wc_i_afe;             % V/(A*s)

% Outer DC link voltage loop.  Gain from id to DC link current is
% 1.5*Vph_peak/Vlink;  plant is the link capacitor 1/(s*Clink).
mg.wc_v_afe      = 300;                              % rad/s
mg.Kp_v_afe      = mg.wc_v_afe*mg.Clink/(1.5*mg.Vph_peak/mg.Vlink_ref);
mg.Ki_v_afe      = mg.Kp_v_afe*mg.wc_v_afe/10;

% PLL
mg.Ts_pll        = 50e-6;      % s   PLL sample time (multiple of the 5 us plant Ts)

%% ------------------------------------------------------------------------
%  Grid-side bidirectional DC/DC  (1600 V link  <->  800 V bus)
%  ------------------------------------------------------------------------
mg.fsw_gdc       = 10e3;       % Hz
mg.Lgdc          = 0.8e-3;     % H
mg.Rgdc          = 8e-3;       % ohm
mg.Cgdc_bus      = 1e-3;       % F    bus-side filter capacitor
mg.Dgdc_nom      = mg.Vbus_nom/mg.Vlink_ref;         % 0.5 nominal duty
mg.Dgdc_min      = 0.05;       % duty limits
mg.Dgdc_max      = 0.95;

% Bus-side current rating of the grid converter
mg.Igrid_max     = mg.Sgrid_rated/mg.Vbus_nom;       % A  ~312

% Provisional inner current-loop gains for the grid DC/DC.  The droop
% controller's inner loop drives this converter's duty, so its gains must
% match this plant:  d(i)/dt = (D*Vlink - Vbus)/Lgdc.
% Internal model control:  Kp = Lgdc*wc/Vlink ,  zero placed at Rgdc/Lgdc.
% PROVISIONAL VALUES - the full droop design (slopes, outer loop, bidirectional
% limits) came later, with the droop layer.
mg.wc_i_gdc      = 2*pi*1000;                        % rad/s
mg.Kp_i_gdc      = mg.Lgdc*mg.wc_i_gdc/mg.Vlink_ref; % duty per A
mg.Ki_i_gdc      = mg.Kp_i_gdc*mg.Rgdc/mg.Lgdc;

%% ------------------------------------------------------------------------
%  Droop layer
%  ------------------------------------------------------------------------
%  Battery and grid each run one instance of the same reusable library block,
%  microgridLib/DC Droop Node:
%
%       Iref = sat( deadband( V0 - LPF(Vbus) ) / R )
%
%  Pure proportional statism - no integrator anywhere on the bus voltage.
%  Each unit reads only the bus voltage, so no communication path is needed
%  between converters: the bus voltage IS the communication.  Two integrating
%  units in parallel would each drive the bus to their own set-point and
%  fight, and exact regulation would destroy the load sharing that droop
%  exists to provide.  The bus is therefore expected to sag with load.
%
%  Slopes are sized so a unit reaches its rated current when the bus has
%  deviated by mg.Vdroop_band from that unit's set-point.
mg.Vdroop_band   = 20;         % V   bus deviation at rated current

% Battery droop.  Slope is volts of BUS deviation per amp of BATTERY-side
% current, because that is what the battery converter's inner loop controls.
mg.Rdroop_bat    = mg.Vdroop_band/mg.Ibat_max;       % V/A  ~0.0222
mg.DB_bat        = 0;          % V   no dead band

% Grid droop, on bus-side current.
mg.Rdroop_grid   = mg.Vdroop_band/mg.Igrid_max;      % V/A  ~0.064
mg.DB_grid       = 0;          % V   the supervisor orders the sources instead

% Set-points.  These are wired as SIGNALS, not constants, so the
% supervisor can shift them for the SOC target and for island vs
% grid-connected operation without any rewiring.
mg.V0_bat        = mg.Vbus_nom;                      % 800 V
mg.V0_grid       = mg.Vbus_nom;                      % 800 V

% Measurement filter.  Fast enough not to add phase lag near the droop
% crossover, slow enough to reject the 10 kHz switching ripple.
mg.Tf_droop      = 0.5e-3;     % s

%  DC BUS CAPACITANCE - set by the droop design, not by ripple
%  ------------------------------------------------------------------------
%  With proportional droop the closed-loop bandwidth is not a free choice:
%
%        K = 1/R_bat*Dbat_nom + 1/R_grid  ~ 30 A/V   (bus-side)
%        crossover  =  K / C_bus
%
%  The droop band and the bus capacitance TOGETHER fix the loop speed.  At
%  the 4.7 mF the PV boost carries as its own ripple capacitor, crossover
%  lands at ~1000 Hz - exactly on top of the converters' inner current
%  loops, and the whole bus oscillates.  Sizing the bus for a 600 rad/s
%  droop loop needs ~50 mF, which for a 200 kW / 800 V bus is 16 kJ, or
%  about 80 ms of ride-through: an ordinary figure for a DC microgrid.
%  4.7 mF was never a bus capacitor, it was a converter ripple capacitor.
mg.wc_droop      = 600;                              % rad/s  target droop bandwidth
mg.Kdroop_total  = 1/mg.Rdroop_bat*mg.Dbat_nom + 1/mg.Rdroop_grid;   % A/V
mg.Cbus          = 50e-3;      % F   dedicated DC bus capacitor
mg.Cbus_ESR      = 1e-3;       % ohm

% PV droop, for voltage-control mode.  PV keeps its own voltage
% loop, so droop only shapes its set-point.
mg.Ipv_rated     = mg.Pbus_rated/mg.Vbus_nom;        % A  bus-side, 250
mg.Rdroop_pv     = mg.Vdroop_band/mg.Ipv_rated;      % V/A  0.08  (NOT USED - see the notes in the report)
mg.Vpv_ref_min   = mg.Vbus_nom;                      % V  never droop below nominal

% The grid current reference may go negative, so the converter
% can export as well as import.  The topology allows it;
% this is the controller limit that was blocking it.
mg.Igrid_min     = -mg.Igrid_max;                    % A

%% ------------------------------------------------------------------------
%  Supervisor
%  ------------------------------------------------------------------------
%  The droop layer decides HOW the sources share.  The supervisor decides
%  WHO is allowed to, by moving each node's set-point V0 and clamping its
%  current limits.  It never touches a duty cycle - every command still
%  reaches the plant through the droop nodes.
%
%  Grid-connected
%     PV runs MPPT and its output is used first, by construction.
%     The battery is biased toward SOC_target: below it the battery is
%     blocked from discharging, so the deficit comes from the GRID, which is
%     what the specification asks for.  Above it the battery is released and
%     discharges back down toward the target.
%  Islanded
%     No grid.  The SOC bias is removed - the battery takes whatever the PV
%     cannot place in the loads, all the way to SOC_max - and when it can
%     take no more the bus rises until PV curtails at Vpv_ctrl_ref.

mg.t_island      = 0.7;        % s   grid breaker opens
%  NOTE: this drives BOTH the AC breaker's switching time and the supervisor's
%  island flag, so the control and the plant can never disagree.  To run a
%  purely grid-connected scenario set it PAST the stop time (e.g. 10), not to
%  inf - the Three-Phase Breaker and the Step block both need a finite time.

% SOC set-point bias.  V0_bat = Vbus_nom - k*(SOC_target - SOC), so a battery
% below target sits on a LOWER droop line and therefore absorbs; above target
% it sits higher and supplies.  Deliberately gentle: the hard ordering is done
% by the current limits below, this only nudges.
mg.k_soc         = 0.2;        % V per % of SOC error
mg.V0bat_min     = 790;        % V   clamp on the biased set-point
mg.V0bat_max     = 810;        % V

% SOC window
mg.SOC_min       = 15;         % %   never discharge below this
mg.SOC_hyst      = 2;          % %   hysteresis on every SOC comparison

% Safety override: if the bus falls this low the battery discharges whatever
% its SOC policy says, because holding the bus up outranks the SOC target.
mg.Vbus_emerg     = 770;       % V   discharge override engages below this
mg.Vbus_emerg_off = 780;       % V   and releases above this (hysteresis)

% PV curtailment handover (MPPT <-> voltage control)
mg.Vpv_ctrl_on   = mg.Vpv_ctrl_ref;   % V  850, leave MPPT and hold the bus
mg.Vpv_ctrl_off  = 840;               % V  return to MPPT

%% ------------------------------------------------------------------------
%  Switching device defaults
%  ------------------------------------------------------------------------
mg.Ron           = 1e-3;       % ohm  IGBT/diode on-state resistance
mg.Resr          = 10e-3;      % ohm  series ESR added to bus capacitors so they are
                               %      not in parallel with an ideal voltage source
mg.Rsnub         = 1e5;        % ohm  snubber resistance
mg.Csnub         = inf;        % F    snubber capacitance (inf = resistive only)

%% ------------------------------------------------------------------------
%  Scenario knobs  (kept here so they are easy to sweep)
%  ------------------------------------------------------------------------
mg.irradiance    = 150;        % W/m2  dashboard knob value in PV + Boost
mg.Rload_idle    = 5000;       % ohm   per-load resistance before a car arrives
mg.Rload_full    = 12.8;       % ohm   per-load resistance at 50 kW / 800 V
%% ------------------------------------------------------------------------
%  Grid reconnection
%  ------------------------------------------------------------------------
%  Islanding was only half a cycle: the breaker opened and never closed.
%  Reconnection is three events, not one, and they must happen in this order:
%
%     t_reconnect            the BREAKER closes.  The grid is back on the
%                            transformer, but the AFE is still gated off and
%                            its control loops still hold whatever they wound
%                            up to while there was nothing to control.
%     t_reconnect+t_resync   the GATES are released.  By then the PLL has had
%                            t_resync to lock onto the restored voltage and
%                            the integrators, held in reset the whole time,
%                            start from zero rather than from their limits.
%
%  Releasing the gates at the same instant the breaker closes would throw a
%  wound-up converter at a live grid - which is how a real AFE trips.
mg.t_reconnect   = 0.82;       % s   breaker recloses (inf = stay islanded)
mg.t_resync      = 0.05;       % s   PLL lock / integrator settling window
%% ------------------------------------------------------------------------
%  Load shedding
%  ------------------------------------------------------------------------
%  The last line of defence, and the only mechanism in the model that can
%  answer "what if the demand is simply more than the sources can deliver".
%  The battery is sized for the park; it is not sized for the park plus a
%  fault, and without shedding that case ends the way the first islanded run
%  did - the battery pinned at its limit and the bus in free fall.
%
%  The rule is deliberately simple, and it is stated in bus volts because the
%  bus voltage is the only thing every unit already agrees on:
%
%      SHED below the droop band ,  RESTORE inside it.
%
%  Nothing sheds while the bus is in its normal 760-840 V band, so shedding
%  cannot fire on a load step or on the islanding transient (which dips to
%  ~783 V).  Loads are dropped in reverse priority - bay 4 first, bay 1 last.
%  Shed thresholds hang below the band floor; restore thresholds hang below
%  NOMINAL, not below the shed points.  That asymmetry is the whole design.
%  Setting restore just above the shed threshold looks like ordinary
%  hysteresis and is not: with one 90 kW bay dropped the islanded bus recovers
%  to 782 V, so a 780 V restore point put the bay straight back, overloaded
%  again, and the scheme oscillated with a 100 ms period.  Referencing restore
%  to the nominal bus states the real condition - PUT LOAD BACK ONLY WHEN THE
%  BUS IS BACK WHERE IT SHOULD BE, i.e. when there is genuine headroom, not
%  merely when the collapse has stopped getting worse.
mg.Vshed         = mg.Vbus_min - [5 15 25 35];   % V  [755 745 735 725]
mg.Vshed_hyst    = 25;         % V   nominal margin the restore points sit under
%  Voltage hysteresis alone is not enough, and the overload scenario proved it.
%  While the battery is pinned at its current limit the droop loop is OPEN -
%  the bus is no longer held by a controller, it is just the capacitor
%  integrating the power imbalance.  Dropping one 90 kW bay then leaves ~113 A
%  charging 50 mF, which takes the bus from 755 V through the 780 V restore
%  threshold in 24 ms.  The bay came back, the bus fell again, and the scheme
%  limit-cycled at 20 Hz.
%
%  So the two directions are decided on two different signals: SHED on the
%  instantaneous bus, RESTORE only on a bus that has been healthy for a while.
%  One slow filter and a max() do it - see build_09_shed_restore_lag.m.  This is
%  what real shedding schemes mean by a restore delay.
mg.Tf_reshed     = 50e-3;      % s   recovery must be sustained this long
mg.Vshed_rst     = mg.Vbus_nom - [10 15 20 25];   % V  [790 785 780 775]
mg.Rload_open    = 1e6;        % ohm  a shed bay is an open circuit
%% ------------------------------------------------------------------------
%  EV charging sessions
%  ------------------------------------------------------------------------
%  The four loads used to be hand-written two-step profiles pasted into the
%  From Workspace blocks.  They are now generated from session descriptions by
%  evLoadProfile.m, so a charging bay is described the way a charging bay
%  actually behaves - arrive, charge at constant power, taper on CV, unplug -
%  instead of as a resistance someone typed.
%
%  The arrivals are still the sharp steps you asked to keep ("the interesting
%  points are the load jumps anyway"); the taper and the departure are what
%  makes the rest of the profile a session rather than a square wave.
%
%  Nothing here is tied to the 1 s horizon.  Spread the times over an hour and
%  the same generator produces an hour-long profile.
mg.Pload_peak    = 50e3;       % W   per-bay rated charging power
%  Scenario knob used only by microgridScenario.m - see the notes there.
mg.Poverload_bay = 90e3;       % W   per-bay power in the overload scenario
                               %     (4 x 90 kW = 360 kW against a 250 kW pack)
mg.Tend          = 1;          % s   horizon the profiles are generated for
mg.evSessions = struct( ...
    'tArrive', {0.25,  0.35,  0.45,  0.55}, ...
    'tTaper',  {0.87,  inf,   0.90,  inf }, ...
    'tDepart', {inf,   0.95,  inf,   inf }, ...
    'fracEnd', {0.30,  1.00,  0.50,  1.00});
mg.evLoad = evLoadProfile(mg.evSessions, mg.Vbus_nom, mg.Rload_idle, ...
                          mg.Tend, mg.Pload_peak);

clear ans
