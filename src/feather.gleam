import feather/migrate
import gleam/int
import gleam/option.{type Option, None}
import gleam/result
import sqlight.{type Connection, type Error}

/// Runs the feather cli to generate new migrations and dump the schema
/// you probably don't wanna run this yourself...
/// run `gleam run -m feather` to find out more
pub fn main() {
  migrate.main()
}

pub type JournalMode {
  JournalDelete
  JournalTruncate
  JournalPersist
  JournalMemory
  JournalWal
  JournalOff
}

pub type SyncMode {
  SyncExtra
  SyncFull
  SyncNormal
  SyncOff
}

pub type TempStore {
  TempStoreDefault
  TempStoreFile
  TempStoreMemory
}

pub type Config {
  Config(
    file: String,
    journal_mode: JournalMode,
    synchronous: SyncMode,
    temp_store: TempStore,
    mmap_size: Option(Int),
    page_size: Option(Int),
  )
}

pub fn default_config() -> Config {
  Config(
    "./sqlite.db",
    journal_mode: JournalWal,
    synchronous: SyncNormal,
    temp_store: TempStoreMemory,
    mmap_size: None,
    page_size: None,
  )
}

pub fn connect(config: Config) -> Result(Connection, Error) {
  use connection <- result.try(sqlight.open(config.file))

  let journal_mode = case config.journal_mode {
    JournalOff -> "OFF"
    JournalWal -> "WAL"
    JournalDelete -> "DELETE"
    JournalMemory -> "MEMORY"
    JournalTruncate -> "TRUNCATE"
    JournalPersist -> "PERSIST"
  }

  let sync = case config.synchronous {
    SyncOff -> "OFF"
    SyncFull -> "FULL"
    SyncExtra -> "EXTRA"
    SyncNormal -> "NORMAL"
  }

  let temp_store = case config.temp_store {
    TempStoreFile -> "FILE"
    TempStoreMemory -> "MEMORY"
    TempStoreDefault -> "DEFAULT"
  }

  use _ <- result.try(sqlight.exec(
    "PRAGMA journal_mode = " <> journal_mode <> ";",
    connection,
  ))
  use _ <- result.try(sqlight.exec(
    "PRAGMA synchronous = " <> sync <> ";",
    connection,
  ))
  use _ <- result.try(sqlight.exec(
    "PRAGMA temp_store = " <> temp_store <> ";",
    connection,
  ))
  use _ <- result.try(
    option.map(config.mmap_size, int.to_string)
    |> option.map(fn(size) {
      sqlight.exec("PRAGMA mmap_size = " <> size <> ";", connection)
    })
    |> option.unwrap(Ok(Nil)),
  )

  use _ <- result.try(
    option.map(config.page_size, int.to_string)
    |> option.map(fn(size) {
      sqlight.exec("PRAGMA page_size = " <> size <> ";", connection)
    })
    |> option.unwrap(Ok(Nil)),
  )

  Ok(connection)
}

/// runs "PRAGMA optimize;" before closing the connection.
/// If the connections are long-lived, then consider running
/// this periodically anyways.
pub fn disconnect(connection: Connection) {
  let _ = sqlight.exec("PRAGMA optimize;", connection)
  sqlight.close(connection)
}

pub fn optimize(connection: Connection) {
  sqlight.exec("PRAGMA optimize;", connection)
}
