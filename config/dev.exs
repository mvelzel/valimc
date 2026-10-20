import Config

# A local development server makes every player an operator, so commands can be
# tried by hand; production starts with none (`VALIMC_OPERATORS`).
config :valimc, operators: :all
