## Core data types for the **desim** package
##
## Remember to compile with ``--multimethods:on``

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
    events: HeapQueue[Event]
    quitTime: SimulationTime
    quitRequested: bool

  Event = ref object
    ## An Event controls the flow of time and communication within the
    ## simulation. It is implicitly created by the **desim** framework.
    msg: Message
    time: SimulationTime
    endpoint: LinkEndpoint

  Component* = ref object of RootObj
    ## Base class for all components, which are the basic buiding
    ## block of the simulation. Each component automatically has a
    ## reference to the simulator once created. This allows components
    ## to access simulation-wide attributes like the `current
    ## time<#currentTime,Simulator>`_.
    ##
    ## To create a new component, subclass and create a new ``start``
    ## method.
    ##
    ## Example:
    ##
    ## .. code-block:: nim
    ##
    ##   type
    ##     MyMessage = ref object of Message
    ##       msg*: string
    ##     MyComponent = ref object of Component
    ##       myLink*: Link
    ##
    ##   proc newMyComponent*(): MyComponent =
    ##     ## Not necessary but helps encapsulation and readability
    ##     return MyComponent(myLink: newLink(10))
    ##   method start*(comp: FooComponent) =
    ##     myLink.send(MyMessage(msg: "hello, world!"))
    ##   method receiveMessage*(comp: MyComponent, msg: Message) {.base.} =
    ##     raise newException(system.Exception, "Unexpected message type")
    ##   method receiveMessage*(comp: MyComponent, msg: MyMessage) =
    ##     echo msg.msg
    ##
    ## All links and endpoint methods (e.g. ``receiveMessage``) must
    ## be exported so that
    ## `connect<#connect,Simulator,Link,LinkEndpoint>`_ works
    ## properly. Similarly ``start`` must be exported.
    sim*: Simulator

  Message* = ref object of RootObj
    ## Base class for messages sent over links.

  BaseLink* = object of RootObj
    ## Base class for links. Messages sent over links may or may not
    ## be copied, so they must be treated as immutable.
    latency: SimulationTime
    sim: Simulator

  Link* = object of BaseLink
    ## Represent a connection from one component to another. Each link
    ## is associated with a base latency. All messages sent on this
    ## link have at least that latency, but may have additional
    ## latency added with the `send proc<#send,Link,Message>`_. This
    ## minimum latency allows the simulation framework to more
    ## efficiently parallelize the components.
    ##
    ## A ``Link`` is associated with outgoing messages only. Incoming
    ## messages are handled by creating a ``method`` taking a
    ## ``Component`` subclass and ``Message`` subclass as its only two
    ## arguments. See `Component<#Component>`_.
    endpoint: LinkEndpoint

  BcastLink* = object of BaseLink
    ## Represent a connection from one component to many. For
    ## efficicency, the message is not copied.
    endpoints: seq[LinkEndpoint]

  LinkEndpoint = proc (msg: Message) {.closure.}
    ## The type of each LinkEndpoint. We use a closure to capture the
    ## ``Component`` and endpoint method are combined in one object.

  SimulationError* = object of CatchableError
    ## Base exception for all exceptions raised by the simulation.

#
# Event
#

proc `<`(e0, e1: Event): bool =
  e0.time < e1.time

#
# Component
#

# Base method for component's initialization methods
method start(comp: Component) {.base.} =
  discard

#
#  Simulator methods
#

proc newSimulator*(quitTime: SimulationTime = 0): Simulator =
  return Simulator(components: @[], events: initHeapQueue[Event](),
                   quitTime: quitTime)

proc currentTime*(sim: Simulator): SimulationTime =
  return sim.currentTime

method connectLink(sim: Simulator, link: var BaseLink,
                   endpoint: LinkEndpoint) {.base.} =
  link.sim = sim

method connectLink(sim: Simulator, link: var Link, endpoint: LinkEndpoint) =
  procCall connectLink(sim, BaseLink(link), endpoint)
  if link.endpoint != nil:
    raise newException(SimulationError, "Link was already connected")
  link.endpoint = endpoint

method connectLink(sim: Simulator, link: var BcastLink,
                   endpoint: LinkEndpoint) =
  procCall connectLink(sim, BaseLink(link), endpoint)
  link.endpoints.add(endpoint)

macro connect*(sim: Simulator, fromComp: Component, link: untyped, toComp: Component, endpoint: untyped): untyped =
  ## Connect a link and an endpoint.
  # Note: This macro takes its components separately so that later we
  # can automatically separate clusters of components by thread.
  let doconnect = bindSym"connectLink"
  result = quote do:
    # If the user constructs this from a for-loop over the toComp,
    # then the closure will close over the variable name, so all
    # closures will get the last value. We avoid this by passing that
    # as an argument to makeClosure which ensures it is copied.

    # This proc may have visibility outside of this macro, and I
    # forget how to change that.
    proc makeClosure(c: auto): auto =
      return proc (msg: Message) = `endpoint`(c, msg)
    `doconnect`(`sim`, `fromComp`.`link`, makeClosure(`toComp`))

proc register*(sim: Simulator, comp: Component) =
  ## Register a component with the simulator. Must be called before
  ## ``run``.

  if comp.sim != nil:
    raise newException(SimulationError, "Component already registered")

  comp.sim = sim
  sim.components.add(comp)

proc advanceTime(sim: Simulator) =
  ## Advance time based on the next event to occur
  if sim.events.len != 0:
    sim.currentTime = sim.events[0].time

proc keepGoing(sim: Simulator): bool =
  ## Return whether to continue processing events.
  return (not sim.quitRequested and
          sim.events.len > 0 and
          (sim.quitTime == 0 or sim.quitTime >= sim.currentTime))

proc addEvent(sim: Simulator, event: Event) =
  ## Add another event to the queue
  sim.events.push(event)

proc processNextEvent(sim: Simulator) =
  ## Get the next event on the queue and proccess it.
  let event = sim.events.pop
  event.endpoint(event.msg)

proc run*(sim: Simulator) =
  ## Run the simulation until no more messages remain or another
  ## termination condition is met.

  for comp in sim.components:
    start(comp)

  sim.advanceTime

  while sim.keepGoing:
    sim.processNextEvent
    sim.advanceTime

proc quit*(sim: Simulator) =
  ## Tell the simulator to stop processing new messages. The simulator
  ## will quit once control is returned, usually at the end of the
  ## message handler currently being executed.
  sim.quitRequested = true

#
# Link
#

proc newLink*(latency: SimulationTime): Link =
  ## Create a new ``Link`` with a minimum latency.
  # The other fields are set when connected
  return Link(latency: latency)

proc send*(link: var Link, amsg: Message, extraDelay=0) =
  ## Send a message over a ``Link``. Adds any value for `extraDelay`
  ## to the latency and uses that as the total delay for this
  ## message. A message sent on a link does not have to wait for all
  ## previously sent messages to arrive if their delay time is greater
  ## than its.

  if link.endpoint == nil:
    raise newException(SimulationError, "Link was not connected")

  var
    totalLatency = link.latency + extraDelay
    event = Event(msg: amsg,
                  time: link.sim.currentTime + totalLatency,
                  endpoint: link.endpoint)
  link.sim.addEvent(event)

proc send*(link: var BcastLink, msg: Message, extraDelay=0) =
  ## Send a message over a ``BcastLink``. Adds any value for
  ## `extraDelay` to the latency and uses that as the total delay for
  ## this message. A message sent on a link does not have to wait for
  ## all previously sent messages to arrive if their delay time is
  ## greater than its.
  ##
  ## Unlike a ``Link``, it is not an error to send to an unconnected
  ## ``BcastLink``.

  let
    totalLatency = link.latency + extraDelay

  for endpoint in link.endpoints:
    let
      event = Event(msg: msg,
                    time: link.sim.currentTime + totalLatency,
                    endpoint: endpoint)
    link.sim.addEvent(event)

proc latency*(link: Link): SimulationTime =
  ## The minimum latency of messages sent on this link.
  return link.latency
