## Example of using logging in nim

import desim
import desim/components/logger

type
  ExampleComponent = ref object of Component
    logger: Logger


proc newExampleComponent(): ExampleComponent =
  # TODO: Use logger builder
  ExampleComponent(logger: Logger(link: newBatchLink[LogMessage](),
                                  enabled: true,
                                  timeFormat: "yyyy-MMM-dd hh:mm:ss",
                                  level: LogLevel.all))


component comp, ExampleComponent:
  startup:
    comp.logger.error("Log Test")

proc main() =
  var
    sim = newSimulator()
    comp = newExampleComponent()
    logcomp = newLogComponent()

  sim.register comp
  sim.register logcomp

  connect(comp.logger.link, logcomp.port)

  sim.run

main()
