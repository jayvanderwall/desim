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
    nextEvent: SimulationTime
    components: seq[Component]
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
    name*: string
    sim {.cursor.}: Simulator
    isStartup: bool
    isShutdown: bool
    nextEvent: SimulationTime
      ## When the next event will occur on this component, or noEvent if no
      ## events are pending.

  BaseLink* = object of RootObj
    ## Base class for links. Messages sent over links may or may not
    ## be copied, so they must be treated as immutable.
    latency: SimulationTime
    comp {.cursor.}: Component

  Link*[M] = object of BaseLink
    ## Represent a connection from one component to another. Each link
    ## is associated with a base latency. All messages sent on this
    ## link have at least that latency, but may have additional
    ## latency added with ``send``. This
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

  BatchLink*[M] = object of Link[M]
    ## Connect to a port with implementation-defined latency that may
    ## not be consistent message to message. A BatchLink is useful for
    ## most-efficiently moving simulation metadata such as statistics
    ## or log messages.

  Port*[M] = ref object
    ## Endpoint for messages of type ``M``.
    comp {.cursor.}: Component
    events: HeapQueue[Event[M]]

  Timer*[M] = object
    ## A Timer allows a component to schedule an event in the future
    ## for itself to handle. This acts like a link and port pair for
    ## the same component.
    events: HeapQueue[Event[M]]
    comp {.cursor.}: Component

  SimulationError* = object of CatchableError
    ## Base exception for all exceptions raised by the simulation.

  ComponentItem = concept x
    ## Uniform way of addressing anything stored in a Component that
    ## needs a back reference to the component.
    `comp=`(x, Component)


const noEvent = SimulationTime(-1)

#
# Forward Declarations
#

method runComponent*(comp: Component, sim: Simulator, isStartup = false, isShutdown = false) {.base,locks:"unknown".};

method updateNextEvent(comp: Component) {.base.};

template setBackPointers(c: Component, sim: Simulator) =
  ## Set the component's simulator reference to sim and all the ports,
  ## links, and timers to have a reference to comp.
  c.sim = sim
  for name, value in fieldPairs(c[]):
    when value is ComponentItem:
      value.comp = c
    when value is seq[ComponentItem]:
      for v in mitems(value):
        v.comp = c

#
# Event
#

proc `<`*[M](e0, e1: Event[M]): bool =
  ## Compare two events by time. This is exported so the heap works
  ## properly in generic code in this module.
  e0.time < e1.time

#
# SimulationTime
#

proc update(t0, t1: SimulationTime): SimulationTime =
  if t0 == noEvent:
    return t1
  if t1 == noEvent:
    return t0
  return min(int(t0), int(t1))

#
#  Simulator methods
#

proc newSimulator*(quitTime = SimulationTime(0)): Simulator =
  return Simulator(quitTime: quitTime, nextEvent: noEvent)


proc currentTime*(sim: Simulator): SimulationTime =
  return sim.currentTime


proc register*[C](sim: Simulator, comp: C) =
  ## Register a component with the simulator. Must be called before
  ## ``run``. Unregistered components can also not be connected.

  sim.components.add comp
  comp.setBackPointers sim


proc keepGoing(sim: Simulator): bool =
  ## Return whether to continue processing events.
  return (not sim.quitRequested and
          sim.nextEvent != noEvent and
          (sim.quitTime == 0 or sim.quitTime >= sim.currentTime))


proc updateTime(sim: Simulator) =
  ## Determine what time the simulator should be set to at the
  ## beginning of a round based on the next event to occur.
  sim.currentTime = sim.nextEvent


proc processComponents(sim: Simulator) =
  ## Call all components main processing once for this time step.
  for comp in sim.components:
    comp.updateNextEvent
    if comp.nextEvent == sim.currentTime:
      comp.runComponent sim


proc updateNextEvent(sim: Simulator) =
  ## Determine the time of the next event
  sim.nextEvent = noEvent
  for comp in sim.components:
    sim.nextEvent = update(sim.nextEvent, comp.nextEvent)


proc run*(sim: Simulator) =
  ## Run the simulation until no more messages remain or another
  ## termination condition is met.

  # Initialize each component
  for comp in sim.components:
    comp.runComponent(sim, isStartup=true)

  sim.updateNextEvent

  while sim.keepGoing:
    sim.updateTime
    sim.processComponents
    sim.updateNextEvent

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
  ## Add this event to the pending list for the port.

  port.events.push event


proc nextEventTime[M](port: Port[M]): SimulationTime =
  ## Return the earliest event time of all events pending on this
  ## port.
  if len(port.events) == 0:
    return noEvent
  else:
    return port.events[0].time


iterator messages[M](port: Port[M], time: SimulationTime): M =
  ## Iterate over all message in this port that happen at this time
  ## step. It is a serious programmatic error if any events are
  ## pending on this port that have a timestamp before the given time.
  assert port.events.len == 0 or port.events[0].time >= time
  while port.events.len() != 0 and port.events[0].time == time:
    yield port.events.pop().msg


iterator allMessages[M](port: var Port[M]): (M, SimulationTime) =
  ## Iterate over all messages regardless of timestep.
  for i in 0..<len(port.events):
    yield (port.events[i].msg, port.events[i].time)

#
# BaseLink
#

proc latency*(link: BaseLink): SimulationTime =
  ## The minimum latency of messages sent on this link.
  return link.latency

#
# Link
#

proc baseNewLink*[M; T: Link[M]=Link[M]](latency: SimulationTime): T =
  ## Create a new ``Link`` with a minimum latency.
  if latency <= 0:
    raise newException(SimulationError, "Invalid link latency " & $latency)
  # The other fields are set when connected
  return T(latency: latency)


proc newLink*[M](latency: SimulationTime): Link[M] =
  return baseNewLink[M, Link[M]](latency)


proc send*[M](link: var Link[M], msg: M, extraDelay=0) =
  ## Send a message over a ``Link``. Adds any value for `extraDelay`
  ## to the latency and uses that as the total delay for this
  ## message. A message sent on a link does not have to wait for all
  ## previously sent messages to arrive if their delay time is greater
  ## than its is.

  if link.port == nil:
    # TODO: Maybe there are actually good use cases for this and the
    # message should just be ignored.
    raise newException(SimulationError, "Link was not connected")

  if extraDelay < 0:
    raise newException(SimulationError, "extraDelay cannot be negative")

  let
    totalLatency = link.latency + extraDelay
    event = Event[M](msg: msg,
                     time: link.comp.sim.currentTime + totalLatency)

  link.port.addEvent event


proc connect[M](link: var Link[M], port: Port[M]) =
  link.port = port

#
# BcastLink
#

proc newBcastLink*[M](latency: SimulationTime): BcastLink[M] =
  ## Create a new ``BcastLink`` with a minimum latency.
  # The other fields are set when connected
  if latency <= 0:
    raise newException(SimulationError, "Invalid link latency " & $latency)

  return BcastLink[M](latency: latency)


proc send*[M](link: var BcastLink[M], msg: M, extraDelay=0) =
  ## Send a message over a ``BcastLink``. Adds any value for
  ## `extraDelay` to the latency and uses that as the total delay for
  ## this message. A message sent on a link does not have to wait for
  ## all previously sent messages to arrive if their delay time is
  ## greater than its.
  ##
  ## Unlike a ``Link``, it is not an error to send to an unconnected
  ## ``BcastLink``.

  if link.ports.len == 0:
    # This means no connections were made
    return

  if extraDelay < 0:
    raise newException(SimulationError, "extraDelay cannot be negative")

  let
    totalLatency = link.latency + extraDelay
    event = Event[M](msg: msg,
                     time: link.comp.sim.currentTime + totalLatency)

  for port in mitems(link.ports):
    port.addEvent event


proc connect[M](link: var BcastLink[M], port: Port[M]) =
  link.ports.add port

#
# BatchLink
#

proc newBatchLink*[M](): BatchLink[M] =
  ## Create a new BatchLink. The simulator framework will determine
  ## the latency.
  # Until we have multi-threading or processing on different ranks or
  # compute nodes there isn't much benefit to having anything other
  # than a 1 tick delay.
  return baseNewLink[M, BatchLink[M]](1)

#
# Timer
#

proc newTimer*[M](): Timer[M] =
  return Timer[M]()


proc set*[M](timer: var Timer[M], msg: M, delay: SimulationTime) =
  ## Set this timer to emit a message at some time in the future.
  if delay <= 0:
    raise newException(SimulationError, "Timer delay must be > 0")
  let
    time = timer.comp.sim.currentTime + delay
  timer.events.push Event[M](msg: msg, time: time)


iterator messages[M](timer: var Timer[M], time: SimulationTime): M =
  ## Iterate over all message in this timer that happen at this time
  ## step. It is a serious programmatic error if any events are
  ## pending on this timer that have a timestamp before the given time.
  assert timer.events.len == 0 or timer.events[0].time >= time
  while timer.events.len() != 0 and timer.events[0].time == time:
    yield timer.events.pop().msg


iterator allMessages[M](timer: var Timer[M]): (M, SimulationTime) =
  ## Iterate over all messages regardless of timestep.
  for event in timer.events:
    yield (event.msg, event.time)


proc nextEventTime[M](timer: Timer[M]): SimulationTime =
  ## Return the earliest event time of all events pending on this
  ## timer.
  if len(timer.events) == 0:
    return noEvent
  else:
    return timer.events[0].time

#
# Connected Component
#

proc connect*[L: BaseLink, M](link: var L, port: Port[M]) =
  ## Connect a link and a port.

  if link.comp != nil and port.comp != nil:
    if link.comp.sim != port.comp.sim:
      raise newException(SimulationError,
                         "Cannot connect components with different simulators")

  # Note: This doesn't recurse because in this context the other
  # connect procs are more specific that the one we're in.
  link.connect port

#
# Component
#

method runComponent*(comp: Component, sim: Simulator, isStartup = false, isShutdown = false) {.base,locks:"unknown".} =
  ## Base method for the implementations of each component. This is
  ## run once at component startup, whenever new messages arrive, and
  ## once again at component shutdown.
  discard


method updateNextEvent(comp: Component) {.base.} =
  discard


template startup*(startupBody: untyped): untyped {.dirty.} =
  ## Use inside a ``component`` block to create an action that is run
  ## exactly once before the component starts processing messages.
  if desim_isStartup:
    startupBody


template shutdown*(shutdownBody: untyped): untyped {.dirty.} =
  ## Use inside a ``component`` block to create an action that is run
  ## exactly once immediatly before a component ceases processing.
  if desim_isShutdown:
    shutdownBody


iterator messages*[M](timer: var Timer[M]): M =
  ## Iterate over all messages on this timer at this time step. 

  if not timer.comp.isShutdown and not timer.comp.isStartup:
    for msg in timer.messages timer.comp.sim.currentTime:
      yield msg
  timer.comp.nextEvent = update(timer.comp.nextEvent, nextEventTime(timer))


iterator remainingMessages*[M](timer: var Timer[M]): (M, SimulationTime) =
  ## Iterate over all remaining messages and the time they would have
  ## been received at. This is only effective within a shutdown block.

  if timer.comp.isShutdown:
    for msgTime in timer.allMessages:
      yield msgTime


iterator messages*[M](port: var Port[M]): M =
  ## Iterate over all messages on this port at this time step.

  if not port.comp.isShutdown and not port.comp.isStartup:
    for msg in port.messages port.comp.sim.currentTime:
      yield msg
  port.comp.nextEvent = update(port.comp.nextEvent, nextEventTime(port))


iterator remainingMessages*[M](port: var Port[M]): (M, SimulationTime) =
  ## Iterate over all remaining messages and the time they would have
  ## been received at. This is only effective within a shutdown block.

  if port.comp.isShutdown:
    for msgTime in port.allMessages:
      yield msgTime


template ignoreUnused(thing: untyped): untyped =
  ## Instruct the compiler to ignore a symbol if it is unused.
  # Without {.inject.} _ becomes a gensym which is not ignored.
  block:
    let _ {.inject.} = thing


template component*(comp: untyped, ComponentType: untyped, body: untyped): untyped =
  ## Define a component's behavior. This takes the name you want to
  ## refer to the component as, and the component's type, then
  ## introduces a scope to define the behavior of the component.
  ##
  ## This template introduces several other templates locally for
  ## different actions. The ``shutdown`` template takes no arguments
  ## and is run once when the node is cleanly shutdown. The
  ## ``startup`` template is similar and runs on startup. The
  ## ``onMessage`` template takes a port and a name for the messages and
  ## runs its body for each new message. Similarly ``onTimer`` takes a
  ## timer and message name and handles timers. A variable named
  ## ``simulator`` is automatically added to the environment and
  ## refers to the ``Simulator`` type that registered this
  ## ``Component``.
  ##
  ## This template may also add several variables starting with
  ## ``desim_`` to the local namespace, so do not start your variables
  ## with this prefix to avoid collisions.
  ##
  ## Example:
  ## ```nim
  ## component comp, MyComponent:
  ##   startup:
  ##     comp.myLink.send newMsg("hello")
  ##   shutdown:
  ##     log.info("Shutting down", sim.currentTime)
  ##   onMessage comp.myPort, msg:
  ##     log.info("Received message", msg)
  ##   onTimer comp.myTimer, msg:
  ##     log.info("Timer: ", msg)
  ## ```

  bind nextEventTime

  method updateNextEvent*(comp: ComponentType) =
    comp.nextEvent = noEvent
    for name, value in fieldPairs(comp[]):
      when value is Port:
        comp.nextEvent = update(comp.nextEvent, nextEventTime(value))
      when value is Timer:
        comp.nextEvent = update(comp.nextEvent, nextEventTime(value))

  method runComponent*(comp: ComponentType, simulator: Simulator, desim_isStartup = false, desim_isShutdown = false) {.locks:"unknown".} =

    # Inject these symbols for use in the startup and shutdown macros
    let
      desim_isStartup {.inject.} = desim_isStartup
      desim_isShutdown {.inject.} = desim_isShutdown

    # Inject this so the user has a reference to the simulator
    let
      simulator {.inject.} = simulator
    ignoreUnused simulator

    comp.nextEvent = noEvent
    comp.isStartup = desim_isStartup
    comp.isShutdown = desim_isShutdown

    body


proc `comp=`*[I: BaseLink|Timer|Port](item: var I, comp: Component) =
    ## Set the Component backpointer for a port, link, or timer. This
    ## is normally not necessary, but if an item is stored in an
    ## unusual way (i.e. not a field or inside a seq) then this must
    ## be called manually before connecting the item.
    if item.comp != nil and item.comp != comp:
      raise newException(SimulationError, "Component already set")
    item.comp = comp
