function R = evLoadProfile(sessions, Vnom, Ridle, tEnd, Ppeak)
%EVLOADPROFILE  Resistance-vs-time profiles for a bank of EV chargers.
%
%   R = evLoadProfile(sessions, Vnom, Ridle, tEnd, Ppeak)
%
%  The four park loads are Variable Resistor blocks, so a charging SESSION has
%  to be expressed as R(t).  A DC fast-charge session is a power profile:
%
%     idle  ->  arrival (step)  ->  constant power (CC)  ->  taper (CV)  ->  departure (step)
%
%  and since P = V^2/R at the nominal bus, R(t) = Vnom^2 / P(t).  The taper is
%  linear in POWER, which makes it hyperbolic in resistance, so it is sampled
%  rather than left to the From Workspace block's linear interpolation.
%
%  Arrivals and departures are emitted as two points 1 us apart, so they stay
%  the sharp steps that make them the interesting events - the taper is the
%  realism, the steps are the test.
%
%  sessions : struct array, one per charger, fields
%       tArrive   s    plugs in            (inf = never arrives)
%       tDepart   s    unplugs             (inf = still charging at tEnd)
%       tTaper    s    CC -> CV transition (inf = no taper)
%       fracEnd   -    power at tDepart as a fraction of Ppeak
%  Vnom     V    bus voltage the resistances are sized at
%  Ridle    ohm  resistance of an empty charger bay
%  tEnd     s    horizon
%  Ppeak    W    per-charger rated power
%
%  R : 1xN cell of [t, ohm] matrices, ready for a From Workspace block.
%
%  Nothing here depends on the 1 s horizon.  Give it session times spread over
%  an hour and it produces an hour-long profile; the model's stop time is the
%  only other thing to change.

if nargin < 5, Ppeak = 50e3; end
eps_t  = 1e-6;                 % step width
nTaper = 12;                   % samples across the CV taper
Rcc    = Vnom^2/Ppeak;

R = cell(1,numel(sessions));
for k = 1:numel(sessions)
    s = sessions(k);
    t = 0;  r = Ridle;

    if isfinite(s.tArrive) && s.tArrive < tEnd
        % --- plug in: a step, not a ramp ---------------------------------
        t(end+1) = s.tArrive - eps_t;  r(end+1) = Ridle;   %#ok<AGROW>
        t(end+1) = s.tArrive;          r(end+1) = Rcc;     %#ok<AGROW>

        tStop = min(s.tDepart, tEnd);
        if isfinite(s.tTaper) && s.tTaper < tStop
            % --- constant current, then the CV taper ---------------------
            t(end+1) = s.tTaper;       r(end+1) = Rcc;     %#ok<AGROW>
            tt = linspace(s.tTaper, tStop, nTaper);
            pp = linspace(Ppeak, Ppeak*s.fracEnd, nTaper);
            for q = 2:nTaper
                t(end+1) = tt(q);      r(end+1) = Vnom^2/pp(q); %#ok<AGROW>
            end
        else
            t(end+1) = tStop;          r(end+1) = Rcc;     %#ok<AGROW>
        end

        if isfinite(s.tDepart) && s.tDepart < tEnd
            % --- unplug: a step back to an empty bay ---------------------
            if t(end) < s.tDepart
                t(end+1) = s.tDepart;      r(end+1) = r(end); %#ok<AGROW>
            end
            t(end+1) = s.tDepart + eps_t;  r(end+1) = Ridle;  %#ok<AGROW>
        end
    end

    if t(end) < tEnd
        t(end+1) = tEnd;  r(end+1) = r(end);  %#ok<AGROW>
    end

    % A From Workspace block needs a strictly increasing time vector, apart
    % from the deliberate 1 us step pairs.  Drop any duplicate a session
    % boundary happened to land on.
    t = t(:); r = r(:);
    keep = [true; diff(t) > 0];
    R{k} = [t(keep), r(keep)];
end
end
