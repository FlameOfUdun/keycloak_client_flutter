/// Log levels for controlling the verbosity of logging output.
enum LogLevel {
  /// Trace level for very detailed logs, typically used for debugging.
  trace,

  /// Debug level for general debugging information.
  debug,

  /// Info level for informational messages that highlight the progress of the application.
  info,

  /// Warning level for potentially harmful situations or important events that are not errors.
  warning,

  /// Error level for error events that might still allow the application to continue running.
  error,

  /// Fatal level for very severe error events that will presumably lead the application to abort.
  fatal,

  /// Off level to disable all logging.
  off;
}