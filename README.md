# Desim

Desim is a Discrete Event Simulator modeled on [SST](http://sst-simulator.org/) but written in Nim and with a focus on making your own custom components. Desim allows you to model your problem with several components that communicate using messages. The structure of Desim focuses on message sending and receiving in a way that will allow parallel execution. At the moment, however, Desim only runs on a single thread.

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
