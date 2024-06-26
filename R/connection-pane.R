#' Return the object hierarchy supported by a connection.
#'
#' Lists the object types and metadata known by the connection, and how those
#' object types relate to each other.
#'
#' The returned hierarchy takes the form of a nested list, in which each object
#' type supported by the connection is a named list with the following
#' attributes:
#'
#' \describe{
#'   \item{contains}{A list of other object types contained by the object, or
#'       "data" if the object contains data}
#'   \item{icon}{An optional path to an icon representing the type}
#' }
#
#' For instance, a connection in which the top-level object is a schema that
#' contains tables and views, the function will return a list like the
#' following:
#'
#' \preformatted{list(schema = list(contains = list(
#'                    list(name = "table", contains = "data")
#'                    list(name = "view", contains = "data"))))
#'
#' }
#' @param connection A connection object, as returned by `dbConnect()`.
#' @return The hierarchy of object types supported by the connection.
#' @export
# nocov start
odbcListObjectTypes <- function(connection) {
  UseMethod("odbcListObjectTypes")
}

#' @export
odbcListObjectTypes.default <- function(connection) {
  # slurp all the objects in the database so we can determine the correct
  # object hierarchy

  # all databases contain tables, at a minimum
  obj_types <- list(table = list(contains = "data"))

  # See if we have views too.  A little more elaborate than just
  # checking if any( table_types == "VIEW" ), because some back-ends
  # may contain VIEW "look-alikes".  For example PostgreSQL/"MATVIEW".
  # The icon url is that of the default Rstudio IDE resource location.
  # It gets automatically pulled in for an object type "view" ( but
  # not for some of the other ones ).  Should we not want to encode that
  # dependency, we can just bring that PNG into this package.
  table_types <- tolower(string_values(odbcConnectionTableTypes(connection)))
  viewlike <- grep("view", table_types, value = TRUE)
  viewlike_types <- sapply(
    viewlike,
    function(i) list(contains = "data", icon = "connections/objects/view.png"),
    simplify = FALSE
  )
  obj_types <- c(obj_types, viewlike_types)

  # check for schema support
  if (connection@info$supports.schema) {
    obj_types <- list(schema = list(contains = obj_types))
  }

  # check for multiple catalogs
  if (connection@info$supports.catalogs) {
    obj_types <- list(catalog = list(contains = obj_types))
  }

  obj_types
}

#' List objects in a connection.
#'
#' Lists all of the objects in the connection, or all the objects which have
#' specific attributes.
#'
#' When used without parameters, this function returns all of the objects known
#' by the connection. Any parameters passed will filter the list to only objects
#' which have the given attributes; for instance, passing \code{schema = "foo"}
#' will return only objects matching the schema \code{foo}.
#'
#' @param connection A connection object, as returned by `dbConnect()`.
#' @param ... Attributes to filter by.
#' @return A data frame with \code{name} and \code{type} columns, listing the
#'   objects.
#' @export
odbcListObjects <- function(connection, ...) {
  UseMethod("odbcListObjects")
}

#' @export
odbcListObjects.OdbcConnection <- function(connection,
                                           catalog = NULL,
                                           schema = NULL,
                                           name = NULL,
                                           type = NULL,
                                           ...) {
  check_string(catalog, allow_null = TRUE)
  check_string(schema, allow_null = TRUE)
  check_string(name, allow_null = TRUE)
  check_string(type, allow_null = TRUE)

  # if no catalog was supplied but this database has catalogs, return a list of
  # catalogs
  if (is.null(catalog)) {
    catalogs <- tryCatch(
      string_values(odbcConnectionCatalogs(connection)),
      error = function(err) character()
    )
    if (length(catalogs) > 0) {
      return(
        data.frame(
          name = catalogs,
          type = rep("catalog", times = length(catalogs)),
          stringsAsFactors = FALSE
        )
      )
    }
  }

  # if no schema was supplied but this database has schema, return a list of
  # schema
  if (is.null(schema)) {
    schemas <- string_values(odbcConnectionSchemas(connection, catalog))
    if (length(schemas) > 0) {
      return(
        data.frame(
          name = schemas,
          type = rep("schema", times = length(schemas)),
          stringsAsFactors = FALSE
        )
      )
    }
  }

  objs <- tryCatch(
    odbcConnectionTables(connection, name, catalog, schema, table_type = type),
    error = function(e) NULL
  )
  # just return a list of the objects and their types, possibly filtered by the
  # options above
  data.frame(
    name = objs[["table_name"]],
    type = tolower(objs[["table_type"]]),
    stringsAsFactors = FALSE
  )
}

#' List columns in an object.
#'
#' Lists the names and types of each column (field) of a specified object.
#'
#' The object to inspect must be specified as one of the arguments
#' (e.g. \code{table = "employees"}); depending on the driver and underlying
#' data store, additional specification arguments may be required.
#'
#' @param connection A connection object, as returned by `dbConnect()`.
#' @param ... Parameters specifying the object.
#' @return A data frame with \code{name} and \code{type} columns, listing the
#'   object's fields.
#' @export
odbcListColumns <- function(connection, ...) {
  UseMethod("odbcListColumns")
}

# given a connection, returns its "host name" (a unique string which identifies it)
computeHostName <- function(connection) {
  paste(
    collapse = "_",
    string_values(c(
      connection@info$username,
      connection@info$dbname,
      if (!identical(connection@info$servername, connection@info$dbname)) connection@info$servername
    ))
  )
}

computeDisplayName <- function(connection) {
  # use DSN if present
  dsn <- connection@info$sourcename
  if (!is.null(dsn) & dsn != "") {
    return(dsn)
  }

  # use the database name as the display name
  display_name <- connection@info$dbname
  server_name <- connection@info$servername
  user_name <- connection@info$username

  # prepend username if present
  server_name <- paste(collapse = "@", string_values(c(user_name, server_name)))

  # add server name (if it isn't already the display name, which can be the case
  # for serverless DBMS)
  if (!identical(server_name, display_name)) {
    display_name <- paste(collapse = " - ", string_values(c(display_name, server_name)))
  }

  display_name
}

validateObjectName <- function(table, view, ..., call = caller_env()) {

  # Handle view look-alike object types
  # ( e.g. PostgreSQL/"matview" )
  args <- list(...)
  arg_names <- names(args)
  viewlike <- grep("view", arg_names, value = TRUE)
  view <- Reduce(`%||%`, args[viewlike], view)

  # Error if both table and view are passed
  check_exclusive(table, view, .frame = call)

  table %||% view
}

#' @export
odbcListColumns.OdbcConnection <- function(connection,
                                           table = NULL,
                                           view = NULL,
                                           catalog = NULL,
                                           schema = NULL,
                                           ...) {
  check_string(table, allow_null = TRUE)
  check_string(view, allow_null = TRUE)
  check_string(catalog, allow_null = TRUE)
  check_string(schema, allow_null = TRUE)

  name <- validateObjectName(table, view, ...)
  # specify schema or catalog if given
  cols <- odbcConnectionColumns_(connection,
    name = name,
    catalog_name = catalog,
    schema_name = schema
  )

  # extract and name fields for observer
  data.frame(
    name = cols[["name"]],
    type = cols[["field.type"]],
    stringsAsFactors = FALSE
  )
}

#' Preview the data in an object.
#'
#' Return the data inside an object as a data frame.
#'
#' The object to previewed must be specified as one of the arguments
#' (e.g. \code{table = "employees"}); depending on the driver and underlying
#' data store, additional specification arguments may be required.
#'
#' @param connection A connection object, as returned by `dbConnect()`.
#' @param rowLimit The maximum number of rows to display.
#' @param ... Parameters specifying the object.
#' @return A data frame containing the data in the object.
#' @export
odbcPreviewObject <- function(connection, rowLimit, ...) {
  UseMethod("odbcPreviewObject")
}

#' @export
odbcPreviewObject.OdbcConnection <- function(connection,
                                             rowLimit,
                                             table = NULL,
                                             view = NULL,
                                             schema = NULL,
                                             catalog = NULL,
                                             ...) {
  check_number_whole(rowLimit)
  check_string(table, allow_null = TRUE)
  check_string(view, allow_null = TRUE)
  check_string(schema, allow_null = TRUE)
  check_string(catalog, allow_null = TRUE)

  # extract object name from arguments
  name <- validateObjectName(table, view, ...)

  # prepend schema if specified
  if (!is.null(schema)) {
    name <- paste(dbQuoteIdentifier(connection, schema),
      dbQuoteIdentifier(connection, name),
      sep = "."
    )
  }

  # prepend catalog if specified
  if (!is.null(catalog)) {
    name <- paste(dbQuoteIdentifier(connection, catalog), name, sep = ".")
  }

  dbGetQuery(connection, odbcPreviewQuery(connection, rowLimit, name),
    n = rowLimit
  )
}

#' Create a preview query.
#'
#' Optimize against the rowLimit argument.  S3 since some
#' back-ends do not parse the LIMIT syntax.  Internal, not expected that
#' users would interact with this method.
#'
#' @param connection A connection object, as returned by `dbConnect()`.
#' @param rowLimit The maximum number of rows to display.
#' @param name Name of the object to be previewed
#' @keywords internal
odbcPreviewQuery <- function(connection, rowLimit, name) {
  UseMethod("odbcPreviewQuery")
}

#' Common top-N syntax ( MYSQL, PSQL, DB2, SNOWFLAKE, etc )
#' @rdname odbcPreviewQuery
odbcPreviewQuery.OdbcConnection <- function(connection, rowLimit, name) {
  paste0("SELECT * FROM ", name, " LIMIT ", rowLimit)
}

#' SQL Server specific top-N syntax
#' @rdname odbcPreviewQuery
`odbcPreviewQuery.Microsoft SQL Server` <- function(connection, rowLimit, name) {
  paste0("SELECT TOP ", rowLimit, " * FROM ", name)
}

#' Teradata specific top-N syntax
#' @rdname odbcPreviewQuery
`odbcPreviewQuery.Teradata` <- function(connection, rowLimit, name) {
  paste0("SELECT TOP ", rowLimit, " * FROM ", name)
}

#' Oracle specific top-N syntax
#' @rdname odbcPreviewQuery
odbcPreviewQuery.Oracle <- function(connection, rowLimit, name) {
  paste0("SELECT * FROM ", name, " WHERE ROWNUM <= ", rowLimit)
}

#' Get an icon representing a connection.
#'
#' @description
#' `r lifecycle::badge("deprecated")`
#' Return the path on disk to an icon representing a connection.
#'
#' @details
#' The icon returned should be a 32x32 square image file.
#'
#' @param connection A connection object, as returned by `dbConnect()`.
#' @return The path to an icon file on disk.
#' @keywords internal
#' @export
odbcConnectionIcon <- function(connection) {
  lifecycle::deprecate_warn(
    "1.4.2",
    "odbcConnectionIcon()"
  )

  odbcConnectionIcon_(connection)
}

odbcConnectionIcon_ <- function(connection) {
  # no icon is returned by default
  ""
}

#' List the actions supported for the connection
#'
#' @description
#' `r lifecycle::badge("deprecated")`
#'
#' Return a list of actions that can be performed on the connection.
#' @details
#'
#' The list returned is a named list of actions, where each action has the
#' following properties:
#'
#' \describe{
#'   \item{callback}{A function to be invoked to perform the action}
#'   \item{icon}{An optional path to an icon representing the action}
#' }
#'
#' @param connection A connection object, as returned by `dbConnect()`.
#' @return A named list of actions that can be performed on the connection.
#' @keywords internal
#' @export
odbcConnectionActions <- function(connection) {
  lifecycle::deprecate_warn(
    "1.4.2",
    "odbcConnectionActions()"
  )

  odbcConnectionActions_(connection)
}

odbcConnectionActions_ <- function(connection) {
  actions <- list()

  if (exists(".rs.api.documentNew")) {
    documentNew <- get(".rs.api.documentNew")
    actions <- c(
      actions,
      list(
        SQL = list(
          icon = system.file("icons/edit-sql.png", package = "odbc"),
          callback = function() {
            varname <- Filter(
              function(e) identical(get(e, envir = .GlobalEnv), connection),
              ls(envir = .GlobalEnv)
            )

            tables <- odbcConnectionTables(connection)
            columnPos <- 6
            if (nrow(tables) == 0) {
              contents <- paste(
                paste0("-- !preview conn=", ifelse(length(varname) > 0, varname[[1]], "")),
                "",
                "SELECT 1",
                "",
                sep = "\n"
              )
            } else {
              firstTable <- tables[1, ]

              tableName <- dbQuoteIdentifier(connection, firstTable$table_name)

              # add schema
              if (!is.na(firstTable$table_schema) && nchar(firstTable$table_schema) > 0) {
                tableName <- paste(dbQuoteIdentifier(connection, firstTable$table_schema), tableName, sep = ".")
              }

              # add catalog
              if (!is.na(firstTable$table_catalog) && nchar(firstTable$table_catalog) > 0) {
                tableName <- paste(dbQuoteIdentifier(connection, firstTable$table_catalog), tableName, sep = ".")
              }

              contents <- paste(
                paste0("-- !preview conn=", varname),
                "",
                paste0("SELECT * FROM ", tableName),
                "",
                sep = "\n"
              )

              columnPos <- 14
            }

            documentNew("sql", contents, row = 2, column = columnPos, execute = FALSE)
          }
        )
      )
    )
  }

  actions <- c(actions, list(
    Help = list(
      # show README for this package as the help; we will update to a more
      # helpful (and/or more driver-specific) website once one exists
      icon = "",
      callback = function() {
        utils::browseURL("https://github.com/rstats-db/odbc/blob/master/README.md")
      }
    )
  ))

  actions
}

on_connection_closed <- function(con) {
  # make sure we have an observer
  observer <- getOption("connectionObserver")
  if (is.null(observer)) {
    return(invisible(NULL))
  }

  type <- con@info$dbms.name
  host <- computeHostName(con)
  observer$connectionClosed(type, host)
}

on_connection_updated <- function(con, hint) {
  # make sure we have an observer
  observer <- getOption("connectionObserver")
  if (is.null(observer)) {
    return(invisible(NULL))
  }

  type <- con@info$dbms.name
  host <- computeHostName(con)
  observer$connectionUpdated(type, host, hint = hint)
}

on_connection_opened <- function(connection, code) {
  # make sure we have an observer
  observer <- getOption("connectionObserver")
  if (is.null(observer)) {
    return(invisible(NULL))
  }

  # find an icon for this DBMS
  icon <- odbcConnectionIcon_(connection)

  # let observer know that connection has opened
  observer$connectionOpened(
    # connection type
    type = connection@info$dbms.name,

    # name displayed in connection pane
    displayName = computeDisplayName(connection),

    # host key
    host = computeHostName(connection),

    # icon for connection
    icon = icon,

    # connection code
    connectCode = code,

    # disconnection code
    disconnect = function() {
      dbDisconnect(connection)
    },
    listObjectTypes = function() {
      odbcListObjectTypes(connection)
    },

    # table enumeration code
    listObjects = function(...) {
      odbcListObjects(connection, ...)
    },

    # column enumeration code
    listColumns = function(...) {
      odbcListColumns(connection, ...)
    },

    # table preview code
    previewObject = function(rowLimit, ...) {
      odbcPreviewObject(connection, rowLimit, ...)
    },

    # other actions that can be executed on this connection
    actions = odbcConnectionActions_(connection),

    # raw connection object
    connectionObject = connection
  )
}
# nocov end
