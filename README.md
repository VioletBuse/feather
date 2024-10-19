# feather

[![Package Version](https://img.shields.io/hexpm/v/feather)](https://hex.pm/packages/feather)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/feather/)

```sh
gleam add feather@v1
```
Add the following fields to your gleam.toml file:

```toml
# this can of course be anything you like
migrations_dir = "./priv/migrations"
schemafile = "./schema.sql"
```

Then run the command `gleam run -m feather -- new "Initial schema migration"` and make any changes you like.

Running the command `gleam run -m feather -- schema` will create the file ./schema.sql, (or whatever you set in your gleam.toml) with the schema of your database after all migrations have been applied.

```gleam
import feather
import feather/migrate
import gleam/result
import gleam/erlang
import sqlight

pub fn main() {
  let assert Ok(priv_dir) = erlang.priv_directory("my_module_name")
  use migrations <- result.try(migrate.get_migrations(priv_dir <> "/migrations"))
  use connection <- feather.connect(feather.Config(..feather.default_config(), file: "./database.db"))
  migrate.migrate(migrations, on: connection)
}
```

Further documentation can be found at <https://hexdocs.pm/feather>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
