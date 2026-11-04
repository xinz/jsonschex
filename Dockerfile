FROM elixir:1.20.5-otp-29-alpine AS builder
WORKDIR /app
ENV MIX_ENV=test
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile
COPY . .
RUN mix compile --warnings-as-errors
CMD ["mix", "test", "--warnings-as-errors"]
