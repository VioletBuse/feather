import argv
import filepath
import gleam/bool
import gleam/dynamic
import gleam/erlang
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/regex
import gleam/result
import gleam/string
import gloml
import justin
import simplifile
import sqlight.{type Connection}

const helptext = "
  gleam run -m feather/migrate -- <command> [options]

  commands:
    new <migration name>
        Generate a new migration script. A timestamp will
        be prepended as the migration id, to ensure ordering
        of migration scripts.

    schema <path to migrations folder>
        Dump the schema of the sqlite database into a schema.sql
        file. Pass in the path (absolute or relative) to the
        migrations directory.
"

fn get_migrations_dir() -> String {
  simplifile.read("gleam.toml")
  |> result.nil_error
  |> result.map(gloml.decode(_, dynamic.field("migrations_dir", dynamic.string)))
  |> result.map(result.map_error(_, fn(_) { Nil }))
  |> result.flatten
  |> result.unwrap("./migrations")
}

fn get_schema_file() -> String {
  simplifile.read("gleam.toml")
  |> result.nil_error
  |> result.map(gloml.decode(_, dynamic.field("schemafile", dynamic.string)))
  |> result.map(result.map_error(_, fn(_) { Nil }))
  |> result.flatten
  |> result.unwrap("./schema.sql")
}

/// Runs the feather cli to generate new migrations and dump the schema
/// you probably don't wanna run this yourself...
/// run `gleam run -m feather` to find out more
pub fn main() {
  let help_flag =
    list.any(argv.load().arguments, fn(flag) {
      case flag {
        "--help" | "-h" | "help" -> True
        _ -> False
      }
    })

  case argv.load().arguments {
    ["new", ..rest] -> handle_new_cmd(rest, help: help_flag)
    ["schema", ..rest] -> handle_schema_dump(rest, help: help_flag)
    _ -> io.println(helptext)
  }
}

const new_cmd_helptext = "
  gleam run -m feather/migrate -- new <migration name>
    options:
      --dir, --migrations-dir, -d Migrations directory location, default: ./migrations
      --help, -h                  Show this help message
"

fn handle_new_cmd(args: List(String), help help_flag: Bool) {
  let timestamp = erlang.system_time(erlang.Second)

  let #(_, dir) =
    list.find(list.window_by_2(args), fn(tuple) {
      case tuple {
        #("--dir", _) | #("--migrations-dir", _) | #("-d", _) -> True
        _ -> False
      }
    })
    |> result.unwrap(#("default", get_migrations_dir()))

  case help_flag, args {
    True, _ -> io.println(new_cmd_helptext)
    _, [] -> io.println("Please provide a migration name")
    _, [name, ..] -> {
      let filename =
        int.to_string(timestamp) <> "_" <> justin.snake_case(name) <> ".sql"
      let path = filepath.join(dir, filename)

      let _ = simplifile.create_file(path)
      let _ = simplifile.write(path, "-- " <> name)

      Nil
    }
  }
}

const schema_dump_helptext = "
  gleam run -m feather/migrate -- schema
    options:
      --migrations-dir, -d    Migrations directory location, default: ./migrations
      --file-name, -f         Name of the resulting file, default: ./schema.sql
"

fn handle_schema_dump(args: List(String), help help_flag: Bool) {
  let #(_, migrations_dir) =
    list.find(list.window_by_2(args), fn(window) {
      case window {
        #("--migrations-dir", _) | #("-d", _) -> True
        _ -> False
      }
    })
    |> result.unwrap(#("", get_migrations_dir()))

  let #(_, outfile) =
    list.find(list.window_by_2(args), fn(window) {
      case window {
        #("--file-name", _) | #("-f", _) -> True
        _ -> False
      }
    })
    |> result.unwrap(#("", get_schema_file()))

  case help_flag {
    True -> io.println(schema_dump_helptext)
    False -> {
      use connection <- sqlight.with_connection(":memory:")

      let schema_result = {
        use migrations <- result.try(get_migrations(migrations_dir))
        use _ <- result.try(migrate(migrations, connection))
        use sql_dumps <- result.try(
          sqlight.query(
            "SELECT * FROM sqlite_schema",
            connection,
            [],
            dynamic.tuple5(
              dynamic.string,
              dynamic.string,
              dynamic.string,
              dynamic.int,
              dynamic.optional(dynamic.string),
            ),
          )
          |> result.map_error(TransactionError),
        )

        Ok(
          list.filter(sql_dumps, fn(row) {
            case row.4 {
              Some(_) -> True
              None -> False
            }
          })
          |> list.map(fn(row) { option.unwrap(row.4, "") }),
        )
      }

      case schema_result {
        Error(err) -> {
          io.debug(err)

          Nil
        }
        Ok(sql_list) -> {
          let _ =
            list.map(sql_list, fn(str) { str <> ";\n\n" })
            |> string.concat
            |> simplifile.write(outfile, _)

          Nil
        }
      }
    }
  }
}

/// Migrations with an id and a sql script
///
pub type Migration {
  Migration(id: Int, up: String)
}

/// Migration error type
pub type MigrationError {
  /// Folder that you gave does not exist
  DirectoryNotExist(String)
  /// The migration script file name is not valid
  InvalidMigrationName(String)
  /// The migration script file has a non-integer id
  InvalidMigrationId(String)
  /// Error starting or comitting the migration transaction
  TransactionError(sqlight.Error)
  /// Error reading/writing/creating the transactions table
  MigrationsTableError(sqlight.Error)
  /// Error applying the migrations script
  MigrationScriptError(Int, sqlight.Error)
}

fn migration_error(error: MigrationError) -> fn(a) -> MigrationError {
  fn(_) { error }
}

/// Pass in a list of migrations and a sqlight connection
///
pub fn migrate(
  migrations: List(Migration),
  on connection: Connection,
) -> Result(Nil, MigrationError) {
  let transaction = {
    use _ <- result.try(
      sqlight.exec("begin transaction;", connection)
      |> result.map_error(TransactionError),
    )
    use _ <- result.try(
      sqlight.exec(
        "create table if not exists storch_migrations (id integer, applied integer);",
        connection,
      )
      |> result.map_error(MigrationsTableError),
    )

    let migrations_decoder = dynamic.tuple2(dynamic.int, sqlight.decode_bool)

    let applications =
      list.try_each(migrations, fn(migration) {
        use migrated <- result.try(
          sqlight.query(
            "select id, applied from storch_migrations where id = ?;",
            on: connection,
            with: [sqlight.int(migration.id)],
            expecting: migrations_decoder,
          )
          |> result.map_error(MigrationsTableError),
        )

        let already_applied = case migrated {
          [] -> False
          [#(_, applied)] -> applied
          _ ->
            panic as "Multiple migrations with the same id in the storch migrations table"
        }

        use <- bool.guard(when: already_applied, return: Ok(Nil))

        use _ <- result.try(
          sqlight.exec(migration.up, connection)
          |> result.map_error(MigrationScriptError(migration.id, _)),
        )
        use _ <- result.try(
          sqlight.query(
            "insert into storch_migrations (id, applied) values (?,?) returning *;",
            on: connection,
            with: [sqlight.int(migration.id), sqlight.bool(True)],
            expecting: migrations_decoder,
          )
          |> result.map_error(MigrationsTableError),
        )

        Ok(Nil)
      })

    use _ <- result.try(applications)

    use _ <- result.try(
      sqlight.exec("commit;", connection) |> result.map_error(TransactionError),
    )
    Ok(Nil)
  }

  case transaction {
    Ok(_) -> {
      Ok(Nil)
    }
    Error(err) -> {
      io.println("error running migration")
      io.debug(err)
      io.println("rolling back")
      let _ = sqlight.exec("rollback;", connection)
      Error(err)
    }
  }
}

/// Get a list of migrations from a folder in the filesystem
/// migration files *must* end in .sql and start with an integer id followed by an underscore
/// example: 0000001_init.sql
///
/// you could store these in the priv directory if you like, that's probably the best way
pub fn get_migrations(
  in directory: String,
) -> Result(List(Migration), MigrationError) {
  use filenames <- result.try(get_migration_filenames(directory))
  use raw_migrations <- result.try(read_migrations(filenames))

  list.map(raw_migrations, fn(raw) { Migration(raw.0, raw.1) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
  |> Ok
}

fn read_migrations(
  scripts paths: List(String),
) -> Result(List(#(Int, String)), MigrationError) {
  list.try_map(paths, fn(path) {
    let filename = filepath.base_name(path)

    use #(id, _) <- result.try(
      string.split_once(filename, "_")
      |> result.map_error(migration_error(InvalidMigrationName(filename))),
    )
    use id <- result.try(
      int.parse(id) |> result.map_error(migration_error(InvalidMigrationId(id))),
    )

    let assert Ok(contents) = simplifile.read(path)

    Ok(#(id, contents))
  })
}

fn get_migration_filenames(
  in directory: String,
) -> Result(List(String), MigrationError) {
  use is_dir <- result.try(
    simplifile.is_directory(directory)
    |> result.map_error(migration_error(DirectoryNotExist(directory))),
  )
  use <- bool.guard(when: !is_dir, return: Error(DirectoryNotExist(directory)))

  use filenames_raw <- result.try(
    simplifile.get_files(directory)
    |> result.map_error(migration_error(DirectoryNotExist(directory))),
  )

  list.map(filenames_raw, fn(path) {
    use extension <- result.try(filepath.extension(path))
    let base_path = filepath.directory_name(path)
    let filename = filepath.base_name(path) |> filepath.strip_extension

    use <- bool.guard(when: extension != "sql", return: Error(Nil))
    use <- bool.guard(when: base_path != directory, return: Error(Nil))

    use #(numbers, _) <- result.try(string.split_once(filename, "_"))

    use regex <- result.try(regex.from_string("^[0-9]+$") |> result.nil_error)
    use <- bool.guard(when: !regex.check(regex, numbers), return: Error(Nil))
    Ok(path)
  })
  |> result.values
  |> Ok
}
