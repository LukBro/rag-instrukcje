# CLAUDE.md

## Komendy

- testy: `bundle exec rspec`
- lint dokumentacji: `bin/rails docs:lint` (gdy zadanie zostanie przeniesione z `rag-package/`)

## Przepływ pracy

- Jedno zgłoszenie = jedna gałąź i jeden PR.
- Nazwa gałęzi zaczyna się od numeru zgłoszenia, np. `bro-12-krotki-opis`.
- Opis PR: `Fixes [BRO-<numer>](https://linear.app/browarek/issue/BRO-<numer>)` + lista
  kryteriów akceptacji; `[x]` tylko przy faktycznie sprawdzonych.
- Przed PR uruchom testy i napraw błędy.
- Zgłoszenia czytaj z Linear (MCP). Zlecanie agentowi: Actions → „Claude ticket” →
  Run workflow → `BRO-<numer>`; poprawki: `@claude …` w PR.

## Kontekst projektu

- Rails 8.1, RSpec, Redis (Query Engine), Ollama (`bge-m3`), Gemini (opcjonalnie).
- Kod bazowy RAG i jego README: `rag-package/`.
- Aplikacja jest **wyłącznie API** (`rails new --api`): bez widoków, helperów i JavaScriptu;
  odpowiedzi tylko JSON; główny endpoint `POST /api/ask`.
- Repozytorium jest **publiczne**: żadnych kluczy, tokenów, haseł ani adresów serwera
  w kodzie, commitach i opisach PR; wartości tylko w zmiennych środowiskowych i sekretach
  GitHub. Wyciek: README → „Wyciek sekretu — co robić”.

## Zakazy

- Nie wypychaj na `main`.
- Nie dodawaj sekretów, kluczy API ani adresów serwera do kodu, commitów i opisów.
- Nie zmieniaj `config/deploy.yml`, `.kamal/`, `.github/workflows/`, chyba że zgłoszenie
  wprost tego wymaga.
- Nie dodawaj autentykacji (dostęp przez tunel SSH).
