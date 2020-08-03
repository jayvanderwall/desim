# Desim

Desim is a [Discrete Event Simulator](https://en.wikipedia.org/wiki/Discrete-event_simulation) modeled on [SST](http://sst-simulator.org/) but written in Nim and with a focus on making your own custom components. Desim allows you to model your problem with several components that communicate using messages. The structure of Desim focuses on message sending and receiving in a way that will allow parallel execution. At the moment, however, Desim only runs on a single thread.

# Quick Examples

## One component Hello World

Below is a simple hello world style program. It creates a single component that prints "Hello, World!" on startup then performs no other actions. The simulation will start this component then immediately stop, as there are no pending messages. This illustrates much of the necessary boilerplate but a useful simulation will have additional functionality.

```nim
import desim

# Define a custom component type
type HelloComponent = ref object of Component

# Define our component's constructor. The rest of its functionality is defined with the component template.
proc newHelloComponent(name: string): HelloComponent =
  HelloComponent(name: name)

# Define our component's behavior. The first argument gives a name to the component to use in this template.
# The second is the type of the component.
component comp, HelloComponent:
  # Define behavior for our component to do on startup
  startup:
    echo "Hello, World!"
  # Define behavior when our component is shut down
  shutdown:
    echo "Goodbye, World"

proc main() =
  var
    # Every simulation requires exactly one Simulator object.
    sim = newSimulator()
    hello = newHelloComponent("hello")

  # All components must be registered before the simulator starts
  sim.register hello
  
  # Run the simulator until a shutdown condition occurs
  sim.run

main()
```

## One Component Timer Hello World

This example still uses one component but adds a timer, which sends a message to its component at some time in the future.

```nim
import desim

type
  HelloComponent = ref object of Component
    # Define a timer object. The messages type is taken as a generic argument to the Timer type
    timer: Timer[string]

proc newHelloComponent(name: string): HelloComponent =
  HelloComponent(name: name)

component comp, HelloComponent:
  startup:
    # Set the timer to go off to send the message "Hello, World!" in 1 tick.
    comp.timer.set("Hello, World!", 1)

  # Iterate over all messages. All messages must be cleared as soon as they are received.
  for msg in messages(comp.timer):
    # The type of msg is the type given as the generic argument to Timer
    echo msg

proc main() =
  var
    sim = newSimulator()
    hello = newHelloComponent("hello")

  sim.register hello
  
  sim.run

main()

```

## Two component Hello World

```nim
import desim

type
  HelloComponent = ref object of Component
    # Messages are sent out on a Link with a given message type
    link: Link[string]
  RecvComponent = ref object of Component
    # Messages of a given type are received on a Port.
    port: Port[string]

proc newHelloComponent(name: string): HelloComponent =
  # All links must be initialized with newLink. It takes the base delay as an argument
  HelloComponent(name: name, link: newLink[string](100))

proc newRecvComponent(name: string): RecvComponent =
  # All ports must be initialized with newPort but take no arguments
  RecvComponent(name: name, port: newPort[string]())

component comp, HelloComponent:
  startup:
    comp.link.send "Hello, World!"

component comp, RecvComponent:
  for msg in messages(comp.port):
    echo msg

proc main() =
  var
    sim = newSimulator()
    hello = newHelloComponent("hello")
    recv = newRecvComponent("recv")

  sim.register hello
  sim.register recv

  # Every Link must be connected to exactly one Port. Multiple Links may connect to the
  # same port.
  connect hello.link, recv.port
  
  sim.run

main()

```

## Logging Hello World

This example uses logging instead of `echo` to print its message. It uses the only pre-defined component which is the `LogComponent`. The logger outputs in JSON but this can be configured.

```nim
import desim
# The LogComponent requires this import
import desim/components/logger

type
  HelloComponent = ref object of Component
    # Although not necessary, it is recommended that you name Logger logger.
    logger: Logger

proc newHelloComponent(name: string): HelloComponent =
  HelloComponent(name: name)

component comp, HelloComponent:
  startup:
    # The logger has convenience methods corresponding to each default log level.
    # In this case we use the info log level.
    comp.logger.info "Hello, World"

proc main() =
  var
    sim = newSimulator()
    hello = newHelloComponent("hello")
    # If the simulation uses logging then it must have one LogComponent
    logcomp = newLogComponent()
    # The LogBuilder is a convenience class that connects components to the LogComponent.
    # It is initialized with a reference to the logging component.
    logbuilder = newLoggerBuilder(logcomp)

  # Indicate that we want to log everything at or above the info level
  logbuilder.setLevel LogLevel.info
  # Connect the hello component's logger to the LogComponent associated with this
  # LoggerBuilder. This by default assumes the Logger is called logger (though this
  # is configurable).
  logbuilder.attach hello

  sim.register hello
  # The LogComponent is a regular component and must be registered
  sim.register logcomp

  sim.run

main()

```

# Types

The operation of a discrete event simulation using Desim requires several types. Most of them have already been introduced in the examples section. More detailed API information can be found by compiling the documentation from the code.

## Simulator

This class is in charge of orchestrating a simulation. Since Desim uses no global variables, all simulation state not contained in a `Component` is found in the `Simulator`. From the user's perspective this is mostly the current simulation time retrieved with the `currentTime` proc. All components must be `register`'d with the same simulator before calling the simulator's `run` command.

## Component

All functionality is expected to be provided by components derived from the `Component` base class. The base class has one user-accessible field, `name`, which can be any string. The `name` is currently not used by the Desim framework but is used by the logging framework. Communication between components requires creating fields that are a `Link`, `Port`, or `Timer`, explained further in their own sections.

The behavior of a component is described with the `component` template. The code inside this macro is run once when the component is first created, once every simulation step in which it will receive at least one message, and once right before it is shut down. Any code in the template will be run every time one of those events happens. To limit code execution to those events, use the `startup` and `shutdown` templates and the `messages` iterator. See the examples section for usage ideas.

## Link

A `Link` object handles the outgoing end of inter-component communication. A `Link` is a generic type that takes the message type as its generic argument. A `Link` will also have a base latency which cannot be zero. This is in immitation of SST, which uses this nonzero latency as a way to automatically separate components into different threads or MPI ranks. While Desim is currently single-threaded, it takes the same approach so as to leave open the option of efficient parallelization in the future. A message is sent with the `send` proc which takes the message and an optional amount of extra time, which is zero by default.

Each `Link` must be connected to exactly one `Port`. It is an error to not connect a `Link` or to connect it to more than one `Port`. The `Port` must accept the same message type as the `Link` sends.

## BcastLink

A `BcastLink` is used to broadcast messages to many `Port` objects. It operates identically to a `Link`, except without the restriction that it be connected to one, or indeed any, `Port`.

## BatchLink

The `BatchLink` type is another type of `Link` which is likely not directly useful. It does not take a latency; rather the framework defines the latency for each message. The framework is therefore free to choose an efficient latency, or buffering scheme, in order to combine communication between components in the most efficient way possible. Since Desim is currently single threaded this is not taken advantage of, but could be.

Since the whole point of a discrete event simulation is to simulate timing of actions between components, this link type is rarely useful. It is used in the logger, since the logger is a component but not part of the domain being simulated. Log messages may thus be batched and efficiently delivered to the logger. This behavior is all hidden from the user.

## Port

All messages sent on a link are received on a `Port`. The `Port` is a generic type that takes the message type as its argument. The messages on a port can be read out using the `messages` iterator inside the `component` template. All messages must be read in the same simulation tick that they are received.

## Timer

A timer takes care of the degenerate, but useful, case where a link and port that are connected together are part of the same component by design. Such self-loops may occur frequently enough to warrant special handling. A `Timer` is also a generic type that takes the message type as its argument. Messages are sent with the `send` proc and received with the `messages` iterator.

## SimulationTime

The time in the simulation is tracked with a `SimulationTime` object. Currently implemented as an `int`, this value will always act like an integer but the actual implementation may change to accommodate larger numbers.

## SimulationError

All exceptions thrown by the Desim framework will be a `SimulationError`.
