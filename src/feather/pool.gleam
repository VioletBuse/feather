import feather
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/otp/actor
import gleam/result
import puddle
import sqlight.{type Connection}

pub type Pool(a) =
  Subject(puddle.ManagerMessage(Connection, a))

pub fn start(
  config: feather.Config,
  count: Int,
) -> Result(Pool(a), actor.StartError) {
  puddle.start(count, fn() { feather.connect(config) |> result.nil_error })
}

pub fn with_connection(pool: Pool(a), timeout: Int, fxn: fn(Connection) -> a) {
  puddle.apply(pool, fxn, timeout, function.identity)
}

/// This will panic if you end the transaction yourself!
pub fn with_transaction(
  pool: Pool(Result(a, Nil)),
  timeout: Int,
  fxn: fn(Connection) -> Result(a, Nil),
) {
  let result =
    with_connection(pool, timeout, fn(connection) {
      use _ <- result.try(
        sqlight.exec("BEGIN TRANSACTION;", connection) |> result.nil_error,
      )
      case fxn(connection) {
        Ok(val) -> {
          let assert Ok(_) = sqlight.exec("COMMIT TRANSACTION;", connection)
          Ok(val)
        }
        Error(Nil) -> {
          let _ = sqlight.exec("ROLLBACK TRANSACTION;", connection)
          Error(Nil)
        }
      }
    })

  result.flatten(result)
}
