## Core data types for the **desim** package
##

import heapqueue
import macros

type

  SimulationTime* = int
    ## The type of all time variables. The simulation proceeds by
    ## discrete ticks. It is up to the user to interpret the meaning
    ## of the ticks.

  Simulator* = ref object
    ## The entirety of the connected simulation. A single
    ## ``Simulator`` object exists for a simulation. The user must
    ## create this and use it to `register<#register>`_ other
    ## `components<#Component>`_.
    currentTime: SimulationTime
    components: seq[Component]
    nextEvent: SimulationTime
    quitTime: SimulationTime
    quitRequested: bool

  Event[M] = object
    ## An Event controls the flow of time and communication within the
    ## simulation. It is implicitly created by the **desim** framework.
    msg: M
    time: SimulationTime

  Component* = ref object of RootObj
    ## Base class for all components, which are the basic buiding
    ## block of the simulation
    ##
    ## Create a component with links and ports as fields. Then define
    ## its functionality using the ``component`` macro.
    nextEvent: SimulationTime
      ## When the next event will occur on this component, or noEvent if no
      ## events are pending. Starts at zero as there is an
      ## "initialization event" pending.

  Message* = ref object of RootObj
    ## Base class for messages sent over links.

  BaseLink* = object of RootObj
    ## Base class for links. Messages sent over links may or may not
    ## be copied, so they must be treated as immutable.
    latency: SimulationTime
    sim: Simulator

  Link*[M] = object of BaseLink
    ## Represent a connection from one component to another. Each link
    ## is associated with a base latency. All messages sent on this
    ## link have at least that latency, but may have additional
    ## latency added with the `send proc<#send,Link,Message>`_. This
    ## minimum latency allows the simulation framework to more
    ## efficiently parallelize the components.
    ##
    ## A ``Link`` is associated with outgoing messages only. Incoming
    ## messages are handled by the ``Port`` type.
    port: Port[M]

  BcastLink*[M] = object of BaseLink
    ## Represent a connection from one component to many. For
    ## efficicency, the message is not necessarily copied.
    ports: seq[Port[M]]

  PortObj[M] = object
    ## Endpoint for messages of type ``M``.
    events: HeapQueue[Event[M]]
    comp {.cursor.}: Component
    sim {.cursor.}: Simulator

  Port*[M] = ref PortObj[M]

  SimulationError* = object of CatchableError
    ## Base exception for all exceptions raised by the simulation.

const noEvent = SimulationTime(-1)

#
# Event
#

proc `<`*[M](e0, e1: Event[M]): bool =
  e0.time < e1.time

#
# SimulationTime
#

proc update*(t0, t1: SimulationTime): SimulationTime =
  if t0 == noEvent:
    return t1
  if t1 == noEvent:
    return t1
  return min(int(t0), int(t1))

#
# Component
#

proc updateNextEvent(comp: Component, nextEvent: SimulationTime) =
  ## Update the next event timer to be the sooner of the current timer
  ## or the input argument.
  comp.nextEvent = update(comp.nextEvent, nextEvent)

method runComponent*(comp: Component, sim: Simulator, isStartup = false, isShutdown = false) {.base.} =
  ## Base method for the implementations of each component. This is
  ## run once at component startup, whenever new messages arrive, and
  ## once again at component shutdown.
  discard

macro component*(comp: untyped, ComponentType: untyped, body: untyped): untyped =
  ## Define a component's behavior. This takes the name you want to
  ## refer to the component as, and the component's type, then
  ## introduces a scope to define the behavior of the component.
  ##
  ## This macro introduces several other templates locally for
  ## different actions. The ``shutdown`` template takes no arguments
  ## and is run once when the node is cleanly shutdown. The
  ## ``startup`` template is similar and runs on startup. The
  ## ``onMessage`` macro takes a port and a name for the messages and
  ## iterates over them. ``useSimulator`` can be used to declare a
  ## name by which you will refer to the simulator object in the rest
  ## of the component definition.
  ##
  ## Example:
  ## ```nim
  ## component comp, MyComponent:
  ##   useSimulator sim
  ##   startup:
  ##     comp.myLink.send newMsg("hello")
  ##   shutdown:
  ##     log.info("Shutting down", sim.currentTime)
  ##   onMessage myPort, msg:
  ##     log.info("Received message", msg.msg)
  ## ```

  let
    shutdown = genSym(kind=nskTemplate, ident="shutdown")
    startup = genSym(kind=nskTemplate, ident="startup")
    simulatorSym = genSym(kind=nskParam, ident="simulator")
    simTime = genSym(kind=nskLet, ident="simTime")
    isShutdown = genSym(kind=nskParam, "isShutdown")
    isStartup = genSym(kind=nskParam, "isStartup")
  result = quote do:
    {.push hint[XDeclaredButNotUsed]:off.}
    method runComponent*(`comp`: `ComponentType`, `simulatorSym`: Simulator, `isStartup` = false, `isShutdown` = false) =
      template `shutdown`(shutdownBody: untyped): untyped {.dirty.} =
        if `isShutdown`:
          shutdownBody
      template `startup`(startupBody: untyped): untyped {.dirty.} =
        if `isStartup`:
          startupBody
      template onMessage(port: untyped, msgName: untyped, onMessageBody: untyped): untyped {.dirty.} =
        if not `isShutdown` and not `isStartup`:
          for msgName in `comp`.port.messages `simTime`:
            onMessageBody
        `comp`.nextEvent = update(`comp`.nextEvent, `comp`.port.nextEventTime)
      template useSimulator(name: untyped): untyped {.dirty.} =
        var name = `simulatorSym`

      `comp`.nextEvent = noEvent
      let `simTime` = `simulatorSym`.currentTime
      `body`
    {.pop.}

#
#  Simulator methods
#

proc newSimulator*(quitTime = SimulationTime(0)): Simulator =
  return Simulator(quitTime: quitTime)

proc currentTime*(sim: Simulator): SimulationTime =
  return sim.currentTime

proc updateNextEvent(sim: Simulator, nextEvent: SimulationTime) =
  sim.nextEvent = update(sim.nextEvent, nextEvent)

proc resetNextEvent(sim: Simulator) =
  sim.nextEvent = noEvent

proc connect*[M](sim: Simulator, fromComp: Component, link: var Link[M], toComp: Component, port: var Port[M]) =
  ## Connect a link and a port.
  link.port = port
  link.sim = sim
  port.sim = sim
  port.comp = toComp

proc register*(sim: Simulator, comp: Component) =
  ## Register a component with the simulator. Must be called before
  ## ``run``.

  sim.components.add comp

proc keepGoing(sim: Simulator): bool =
  ## Return whether to continue processing events.
  return (not sim.quitRequested and
          sim.nextEvent != noEvent and
          (sim.quitTime == 0 or sim.quitTime >= sim.currentTime))

proc run*(sim: Simulator) =
  ## Run the simulation until no more messages remain or another
  ## termination condition is met.

  sim.resetNextEvent

  # TODO: Make onMessage an iterator macro.

  # Initialize each component
  for comp in sim.components:
    comp.runComponent(sim, isStartup=true)

  while sim.keepGoing:
    sim.currentTime = sim.nextEvent
    var nextEvent = noEvent
    for comp in sim.components:
      assert comp.nextEvent == noEvent or comp.nextEvent >= sim.currentTime
      if comp.nextEvent == sim.currentTime:
        comp.runComponent sim
      elif nextEvent == noEvent or comp.nextEvent < nextEvent:
        nextEvent = comp.nextEvent
    sim.nextEvent = nextEvent

  # Finalize each component
  for comp in sim.components:
    comp.runComponent(sim, isShutdown=true)

proc quit*(sim: Simulator) =
  ## Tell the simulator to stop processing new messages. The simulator
  ## will quit once control is returned, usually at the end of the
  ## message handler currently being executed.
  sim.quitRequested = true

#
# Port
#

proc newPort*[M](): Port[M] =
  return Port[M]()

proc addEvent[M](port: var Port[M], event: sink Event[M]) =
  ## Add this event to the pending list for the port, and update the
  ## next event timers for the containing component and the simulator.
  
  port.comp.updateNextEvent event.time
  port.sim.updateNextEvent event.time
  port.events.push event

proc nextEventTime*[M](port: Port[M]): SimulationTime =
  ## Return the earliest event time of all events pending on this
  ## port.
  if len(port.events) == 0:
    return noEvent
  else:
    return port.events[0].time

iterator messages*[M](port: Port[M], time: SimulationTime): M =
  ## Iterate over all message in this port that happen at this time
  ## step. It is a serious programmatic error if any events are
  ## pending on this port that have a timestamp before the given time.
  while port.events.len() != 0:
    assert port.events[0].time >= time
    if port.events[0].time == time:
      yield port.events.pop().msg

#
# Link
#

proc newLink*[M](latency: SimulationTime): Link[M] =
  ## Create a new ``Link`` with a minimum latency.
  # The other fields are set when connected
  return Link[M](latency: latency)

proc send*[M](link: var Link[M], amsg: M, extraDelay=0) =
  ## Send a message over a ``Link``. Adds any value for `extraDelay`
  ## to the latency and uses that as the total delay for this
  ## message. A message sent on a link does not have to wait for all
  ## previously sent messages to arrive if their delay time is greater
  ## than its is.

  if link.port == nil:
    raise newException(SimulationError, "Link was not connected")

  var
    totalLatency = link.latency + extraDelay
    event = Event[M](msg: amsg,
                     time: link.sim.currentTime + totalLatency)

  link.port.addEvent event

proc send*(link: var BcastLink, msg: Message, extraDelay=0) =
  ## Send a message over a ``BcastLink``. Adds any value for
  ## `extraDelay` to the latency and uses that as the total delay for
  ## this message. A message sent on a link does not have to wait for
  ## all previously sent messages to arrive if their delay time is
  ## greater than its.
  ##
  ## Unlike a ``Link``, it is not an error to send to an unconnected
  ## ``BcastLink``.

  # TODO

proc latency*(link: Link): SimulationTime =
  ## The minimum latency of messages sent on this link.
  return link.latency
