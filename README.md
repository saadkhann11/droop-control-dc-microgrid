# Droop-Control DC Microgrid

Simulink model of a droop-controlled 800 V DC microgrid for an EV charging park:
PV with MPPT and a curtailment mode, a battery with a bidirectional DC/DC, a grid
connection through an active front end, four charging bays, and a dump resistor —
all coordinated by decentralised droop controllers that communicate only through
the bus voltage.

Full write-up: **`Microgrid_Record_of_Changes.docx`**

---

## Running it

1. Open MATLAB **R2021b** and set the Current Folder to this folder.
2. Open `microgrid.slx`. The Command Window must print:
   `microgrid: parameters loaded (SolarPVMPPTBoostData + microgridParams).`
   If it does not, stop — nothing below will be meaningful.
3. Press **Run**. One second of model time takes about **35 minutes** of wall clock.
   MATLAB will look frozen; it is not.
4. Open **MASTER SCOPE** for the results. Everything is also in the base workspace
   (`Vdc`, `ILbat`, `Ibat_ref`, `Igrid`, `Vlink`, `SOC`, `island`, `shedLevel`, …).
5. Check what the run produced:

   ```matlab
   microgridCheck('results')
   ```

Default scenario: four bays arrive between 0.25 and 0.55 s, the grid breaker opens
at 0.70 s, recloses at 0.82 s, the converter is released at 0.87 s. The bus stays
between 764 and 799 V throughout.

### Check before you wait

```matlab
microgridCheck          % structure, configuration and every supervisor threshold
```

Seconds to run, and it catches most mistakes without simulating anything. Run it
after **any** change to the model or the parameters.

### If the parameter load fails oddly

An error such as `Undefined function 'mtimes' for input arguments of type 'cell'`
pointing at the PLL almost always means a stray base-workspace variable is
shadowing a MATLAB built-in. Run `clear`, then reopen the model.

---

## What is in this folder

| File | |
|---|---|
| `microgrid.slx` | The model. |
| `microgridLib.slx` | Droop-block library. The model links to it — keep them together. |
| `microgridParams.m` | Every system parameter, in one struct `mg`. Edit here, then reopen the model. |
| `SolarPVMPPTBoostData.mlx` | PV array, boost and MPPT design. Loaded automatically. |
| `evLoadProfile.m` | Builds the charging-bay profiles. Called by `microgridParams`. |
| `microgridCheck.m` | Every check the project carries. |
| `microgridScenario.m` | The three operating cases a normal run cannot reach. |
| `Microgrid_Record_of_Changes.docx` | The report. |

Five files are all the model needs to open and run; the other two are how you
check it still behaves after a change.

You will also see `microgrid.slxc`, `slprj/` and occasional `.autosave`
files appear. These are MATLAB's own build output: they regenerate every time the
model runs, so ignore them, and delete them freely if you ever want to.

---

## `microgridCheck`

```matlab
microgridCheck                 % structure + every supervisor threshold  (seconds)
microgridCheck('results')      % judge the simulation already in the workspace
microgridCheck('all')          % structure + thresholds, then a full run (~35 min)
microgridCheck('thresholds')   % the threshold sweep on its own          (4 s)
```

## `microgridScenario`

```matlab
microgridScenario('list')            % what is available
microgridScenario('soc90')           % battery above target — supplies before the grid
microgridScenario('pvcurtail')       % battery full, PV in surplus — PV holds the bus
microgridScenario('overload')        % demand beyond the pack — bays are shed
microgridScenario('check')           % judge whichever scenario last ran
microgridScenario('restore')         % ALWAYS run this afterwards
```

A scenario **starts** the simulation and returns immediately; the run continues in
the background. Poll it with

```matlab
get_param('microgrid','SimulationStatus')
```

and once that reads `stopped`, call `microgridScenario('check')` — you do not have
to name the scenario again.

---

## Changing the scenario

Everything is in `microgridParams.m`. Edit, save, then reopen the model.

| To do this | Change |
|---|---|
| Stay grid-connected for the whole run | `mg.t_island = 10` — past the stop time. **Not** `inf`. |
| Move the islanding or reconnection | `mg.t_island`, `mg.t_reconnect`, `mg.t_resync` |
| Start at a different state of charge | `mg.SOC0` |
| Change the charging sessions | `mg.evSessions` — arrival, taper and departure per bay |
| Brighter or darker day | the `Solar Irradiance W/m2` gain in `PV + Boost/Irradiance` |
| Retune any threshold or limit | the corresponding `mg.*` field — no block edits needed |

---

## `_archive/`

Nothing here is needed to open, run or test the model.

| Folder | |
|---|---|
| `snapshots/` | The model at each stable point, plus the original as received. Restore by copying one over `microgrid.slx` — note a snapshot still carries the model's earlier name inside it, so Simulink will ask you to confirm the rename on load. *Not in version control.* |
| `build-scripts/` | The twelve idempotent scripts that made the model edits, numbered in the order they run. Only needed to rebuild the model from a snapshot. |
| `superseded/` | Dead ends, interrupted states, and the scripts that `microgridCheck` and `microgridScenario` replaced. |
| `reference/` | Exported subsystem diagrams, run plots, and the working log the report was written from. *Not in version control.* |
| `scratch/` | Console logs and autosaves from the development sessions. |
| `original-downloads/` | Personal zip files, moved out of the way and otherwise untouched. |

Only `build-scripts/` is version-controlled; the rest of `_archive/` stays on
disk only, along with MATLAB's build output — see `.gitignore`.
