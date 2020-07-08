## Implement a logging component that other components can send log
## messages to. This logger provides several services. All the logs
## are ordered in time. Filtering by log level and sender name are
## also provided.
##

import strutils
import strformat
import sequtils
import times

import desim

type
  LogComponent* = ref object of Component
    ## The component where all log messages are sent and serialized.
    # TODO: Don't export
    port*: Port[LogMessage]
    # Overwrite to log to a different location. Default is stdout
    write*: proc (lm: LogMessage)

  LogMessage* = object
    ## The format for log messages sent to a component. Each message
    ## consists of one or more fields that are keyword: description
    ## pairs. By convention it will contain 'msg', describing the
    ## reason for logging, 'time' with a timestamp, and 'level' with
    ## the level (ERROR, DEBUG, etc).
    fields*: seq[(string, string)]

  Logger* = object
    ## An interface to the logger that is stored in each component
    ## doing logging. It takes care of all filtering at the client
    ## side.
    enabled*: bool
    #TODO: Don't export link
    link*: BatchLink[LogMessage]
    timeFormat*: string
    level*: LogLevel

  LoggerRef* = ref Logger

  LoggerBuilder = object
    ## Object for creating many Loggers, each possibly sharing
    ## configuration data.

  LoggableObject* = concept lo
    ## Generic way to refer to an object that can be logged. Here
    ## anything that can be converted to a string can be logged.
    $lo is string

  LogLevel* {.pure.} = enum
    ## Represent the log level of a message. The user may filter out
    ## by level. The levels form a hierarchy, such that lower levels
    ## are always included if higher levels are.
    none, error, warning, info, debug, trace, all

#
# LogComponent
#

proc logToStdout(msg: LogMessage) =
  ## Log the given message to standard out.
  stdout.write "{" & join(msg.fields.mapIt(fmt""""{it[0]}": "{it[1]}""""), ", ") &
    "}"


proc newLogComponent*(write = logToStdout): LogComponent =
  ## Create a new LogComponent. By default write all log entries it
  ## receives to stdout.
  LogComponent(port: newPort[LogMessage](), write: write)


component comp, LogComponent:
  onMessage comp.port, msg:
    # Anything that comes here has already been pre-filtered.
    comp.write msg

#
# Logger
#

proc `comp=`*(logger: var Logger, comp: Component) =
  ## This fulfills the ComponentItem concept and allows us to
  ## intialize the port.
  logger.link.comp = comp


proc formatCurrentTime(logger: Logger): string =
  ## Return a string representing the current time.
  return now().format(logger.timeFormat)


proc log*(logger: var Logger, level: string, msg: string, fields: varargs[(string, string)]) =
  ## Log a message unconditionally. Use one of the procs named after
  ## the log level for filtering.
  var
    logMessage = LogMessage(fields: @[("level", level), ("msg", msg), ("time", logger.formatCurrentTime)] & toSeq(fields))
  logger.link.send logMessage


template toStringField(field: (string, LoggableObject)): (string, string) =
  (field[0], $field[1])


template error*(logger: var Logger, msg: string, fields: varargs[(string, string), toStringField]) =
  if logger.enabled and logger.level >= LogLevel.error:
    logger.log($LogLevel.error, msg, fields)
