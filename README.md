# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Dostęp do API

Aplikacja na serwerze to wyłącznie API (bez widoków). Działa w trybie development i
nasłuchuje tylko na `localhost`; z internetu dostępne jest wyłącznie SSH. Dostęp do API
uzyskuje się przez tunel SSH.

### 1. Otwarcie tunelu

Na swoim komputerze otwórz tunel SSH mapujący lokalny port `3001` na port `3000` na
serwerze (port `3001`, bo `3000` zwykle zajmuje lokalna aplikacja Rails):

```bash
ssh -N -L 3001:localhost:3000 ubuntu@<serwer>
```

### 2. Sprawdzenie tunelu

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3001/up
```

Powinno zwrócić `200`.

### 3. Zapytanie do API

```bash
curl -s -X POST http://localhost:3001/api/ask \
  -H 'Content-Type: application/json' \
  -d '{"question":"..."}'
```

### 4. Lokalna aplikacja z czatem

Lokalna aplikacja z czatem (BRO-40) korzysta z adresu `http://localhost:3001` — tunel
musi być w tym czasie otwarty.

### 5. Zamknięcie tunelu

Zatrzymaj proces `ssh` kombinacją `Ctrl+C`.

### Ostrzeżenie

Nie uruchamiaj `rails server -b 0.0.0.0` i nie publikuj portów kontenerów na `0.0.0.0`.
Porty publikowane przez Dockera omijają reguły `ufw` (zob. dokumentacja Docker dot.
[packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)).

## Automatyzacja

Zgłoszenia z Linear z etykietą „agent” można zlecić Claude'owi: GitHub → Actions → „Claude ticket” → Run workflow → numer zgłoszenia (np. `BRO-11`). Claude otwiera PR, który przegląda i scala człowiek.
