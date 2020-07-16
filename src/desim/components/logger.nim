## Implement a logging component that other components can send log
## messages to. This logger provides several services. All the logs
## are ordered in time. Filtering by log level and sender name are
## also provided.
##

import strutils
import strformat
import sequtils
import times
import re
import macros
import options

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
    link: BatchLink[LogMessage]
    timeFormat*: string
    level*: LogLevel

  LoggerRef* = ref Logger

  LoggerBuilder* = object
    ## Object for creating many Loggers, each possibly sharing
    ## configuration data.
    ##
    ## The builder is given various filters. A component may enable or
    ## disable its own logging at runtime via the Logger.enabled
    ## variable, but changing logging filters globally after creating
    ## the Logger objects has no effect.
    comp: LogComponent
    level: LogLevel
    nameRegexs: seq[(Regex, bool)]  # Regex and whether to enable on match
    timeFormat: string

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
# LogMessage
#

proc find*(msg: LogMessage, key: string): Option[string] =
  ## Return the value corresponding to the given key if it exists.
  for (mkey, value) in msg.fields:
    if mkey == key:
      return some value

#
# LogComponent
#

proc logToStdout(msg: LogMessage) =
  ## Log the given message to standard out.
  stdout.write "{" & join(msg.fields.mapIt(fmt"""{escape(it[0])}: {escape(it[1])}"""), ", ") &
    "}\n"


proc newLogComponent*(name = "logger", write: proc (msg: LogMessage) = logToStdout): LogComponent =
  ## Create a new LogComponent. By default write all log entries it
  ## receives to stdout.
  LogComponent(name: name, port: newPort[LogMessage](), write: write)


component comp, LogComponent:
  for msg in messages(comp.port):
    # Anything that comes here has already been pre-filtered.
    comp.write msg

  shutdown:
    for msg, _ in remainingMessages(comp.port):
      comp.write msg

#
# LoggerBuilder
#

proc newLoggerBuilder*(comp: LogComponent): LoggerBuilder =
  ## Create a new logger builder for connecting components to a
  ## central logging component. Call methods on this object to
  ## configure loggers, then build to create one.
  return LoggerBuilder(comp: comp, timeFormat: "yyyy-MMM-dd hh:mm:ss",
                       level: LogLevel.info)


proc setLevel*(builder: var LoggerBuilder, level: LogLevel) =
  ## Set the level filter so that this level and lower all are sent to
  ## the logger.
  builder.level = level


proc enableNameRegex*(builder: var LoggerBuilder, regex: Regex) =
  ## Add a regular expression. If a component's name matches this
  ## regular expression, it will have logging enabled. If no regex's
  ## are given, then all are enabled. The first match of enable or
  ## disable regex's determines the behavior for a given component,
  ## i.e. order matters.
  builder.nameRegexs.add (regex, true)


proc disableNameRegex*(builder: var LoggerBuilder, regex: Regex) =
  ## Add a regular expression. If a component's name matches this
  ## regular expression, it will have logging disabled. If no regex's
  ## are given, then all are enabled. The first match of enable or
  ## disable regex's determines the behavior for a given component,
  ## i.e. order matters.
  builder.nameRegexs.add (regex, false)


proc setTimeFormat*(builder: var LoggerBuilder, format: string) =
  ## Set the time format string that all the loggers will use. By
  ## default chooses something reasonable.
  builder.timeFormat = format


proc checkEnabled*(builder: LoggerBuilder, name: string): bool = 
  ## Return whether building a Logger for a component with the given
  ## name defaults to enabling logging.
  if builder.nameRegexs.len == 0:
    return true
  for (regex, enable) in builder.nameRegexs:
    if match(name, regex):
      return enable
  return false


proc build*(builder: LoggerBuilder, name: string): Logger =
  ## Build a logger according to the options set in this builder.
  Logger(enabled: builder.checkEnabled(name),
         link: newBatchLink[LogMessage](),
         timeFormat: builder.timeFormat,
         level: builder.level)


macro attach*(builder: LoggerBuilder, comp: Component, fieldName: static[string] = "logger") =
  ## Convenience wrapper around the ``build`` proc to add a logger to
  ## a ``Component``. By default expects the field to be named
  ## ``logger``. This will also connect to the logging component. It
  ## can be run before or after registering the components.
  let fieldIdent = newIdentNode(fieldName)
  result = quote do:
    # Do this in 2 steps to avoid ObservableStore warning
    let built = `builder`.build(`comp`.name)
    `comp`.`fieldIdent` = built
    `comp`.`fieldIdent`.comp = `comp`
    connect(`comp`.`fieldIdent`.link, `builder`.comp.port)

#
# Logger
#

proc `comp=`*(logger: var Logger, comp: Component) =
  ## This fulfills the ComponentItem concept and allows us to
  ## intialize the port.
  logger.link.comp = comp


proc link*(logger: var Logger): var BatchLink[LogMessage] =
  logger.link


proc formatCurrentTime(logger: Logger): string =
  ## Return a string representing the current time.
  return now().format(logger.timeFormat)


proc log*(logger: var Logger, level: string, msg: string, fields: varargs[(string, string)]) =
  ## Log a message unconditionally. Use one of the procs named after
  ## the log level for filtering.
  var
    logMessage = LogMessage(fields: @[("level", level), ("msg", msg), ("time", logger.formatCurrentTime)] & toSeq(fields))
  logger.link.send logMessage


template toStringField*(field: (string, LoggableObject)): (string, string) =
  ## Convert a tuple with a string key and LoggableObject value to a
  ## pair of strings. The level templates will run this conversion,
  ## but the compiler will wait until the last moment to do the
  ## conversion, so it will not happen unless the filters pass.
  (field[0], $field[1])


template error*(logger: var Logger, msg: string, fields: varargs[(string, string), toStringField]) =
  if logger.enabled and logger.level >= LogLevel.error:
    logger.log($LogLevel.error, msg, fields)

template warning*(logger: var Logger, msg: string, fields: varargs[(string, string), toStringField]) =
  if logger.enabled and logger.level >= LogLevel.warning:
    logger.log($LogLevel.warning, msg, fields)

template info*(logger: var Logger, msg: string, fields: varargs[(string, string), toStringField]) =
  if logger.enabled and logger.level >= LogLevel.info:
    logger.log($LogLevel.info, msg, fields)

template debug*(logger: var Logger, msg: string, fields: varargs[(string, string), toStringField]) =
  if logger.enabled and logger.level >= LogLevel.debug:
    logger.log($LogLevel.debug, msg, fields)

template trace*(logger: var Logger, msg: string, fields: varargs[(string, string), toStringField]) =
  if logger.enabled and logger.level >= LogLevel.trace:
    logger.log($LogLevel.trace, msg, fields)
