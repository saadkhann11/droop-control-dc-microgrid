function build_06_converter_gate_block(mdl)
%PHASE4_GATE_BLOCK  Trip the grid converter when the microgrid islands.
%
%  WHY.  Zeroing the grid droop node's current limits stops the grid
%  converter being COMMANDED, but it does not stop it SWITCHING.  In the first
%  islanded run the AFE kept modulating into the open breaker: the transformer
%  secondary and the line reactor were still connected to the bridge, so the
%  modulation drove real current through their resistances and drained the DC
%  link out of its own capacitor - 1600 V at 0.70 s, 1068 V at 0.85 s, 802 V
%  at 0.90 s.  Once the link had fallen to the bus voltage the grid-side DC/DC
%  could no longer hold it off, and the BUS started discharging into the dead
%  link at -175 A.  The battery was supplying 253 kW into a 178 kW load and
%  the bus sagged to 724 V.  The energy was going into the grid converter.
%
%  WHAT.  Both gate paths are multiplied by the supervisor's gridEnable
%  signal, which is 1 while grid-connected and 0 once the breaker opens.  This
%  is what a real active front end does on loss of grid - it trips.  With the
%  gates blocked the bridge is just its antiparallel diodes, the link holds its
%  charge, and because the link then stays well above the bus the DC/DC's own
%  diodes never forward-bias either.
%
%  This is a PROTECTION, not a control action, which is why it acts on the
%  gates rather than on a reference: a converter that cannot be commanded must
%  also not be able to act.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');
G  = [mdl '/PCC + Grid'];
gc = [G '/Grid Converter Control'];

targets = { 'Gate block AFE',   1, 'Universal Bridge', 1, [ 640 120]
            'Gate block S_hi',  2, 'S_hi',             1, [ 640 220]
            'Gate block S_lo',  3, 'S_lo',             1, [ 640 320] };

% the supervisor's flag has to be readable in here
if getSimulinkBlockHandle([G '/From gridEnable']) <= 0
    add_block('simulink/Signal Routing/From',[G '/From gridEnable'], ...
              'Position',[540 60 630 80],'GotoTag','gridEnable');
end

n = 0;
for k = 1:size(targets,1)
    name = targets{k,1};
    if getSimulinkBlockHandle([G '/' name]) > 0, continue; end
    srcPort = get_param(gc,'PortHandles').Outport(targets{k,2});
    dstBlk  = [G '/' targets{k,3}];
    dstPort = get_param(dstBlk,'PortHandles').Inport(targets{k,4});
    lin = get_param(srcPort,'Line');
    if lin > 0, delete_line(lin); end

    p = targets{k,5};
    add_block('simulink/Math Operations/Product',[G '/' name], ...
              'Position',[p(1) p(2) p(1)+30 p(2)+50], ...
              'Inputs','2','Multiplication','Element-wise(.*)');
    pp = get_param([G '/' name],'PortHandles');
    add_line(G, srcPort,   pp.Inport(1), 'autorouting','on');
    add_line(G, get_param([G '/From gridEnable'],'PortHandles').Outport(1), ...
                pp.Inport(2), 'autorouting','on');
    add_line(G, pp.Outport(1), dstPort, 'autorouting','on');
    n = n + 1;
end

fprintf('build_06_converter_gate_block: %d gate path(s) gated by gridEnable\n', n);
end
