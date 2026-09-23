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

## Testy

Testy uruchamiasz poleceniem `bundle exec rspec`. CI na GitHubie uruchamia je na każdym PR i przed scaleniem muszą przejść.

## Ochrona przed wyciekiem sekretów

Repozytorium jest **publiczne**. Klucze, tokeny, hasła i adresy serwera trzymamy wyłącznie
w zmiennych środowiskowych i sekretach GitHub. Trzy warstwy ochrony:

| Warstwa | Kiedy działa | Co łapie |
| -- | -- | -- |
| `.gitignore` | przed `git add` | `.env*`, `config/*.key` |
| gitleaks — hook `pre-commit` | przed commitem, lokalnie | sekrety w zmianach do commitu |
| gitleaks w CI + push protection GitHuba | przy push/PR | sekrety w commitach, także od Claude |

### Instalacja hooka (jednorazowo, na każdym komputerze)

Wersja gitleaks jest przypięta: **8.30.1** (ta sama w hooku i w CI). Linux x64:

```bash
cd /tmp
curl -sLO https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
curl -sLO https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt
grep linux_x64 gitleaks_8.30.1_checksums.txt | sha256sum -c -   # ma wypisać: OK
tar -xzf gitleaks_8.30.1_linux_x64.tar.gz gitleaks
install -m 755 gitleaks ~/.local/bin/gitleaks                   # ~/.local/bin musi być w PATH
gitleaks version                                                # 8.30.1
```

Na macOS pobierz `gitleaks_8.30.1_darwin_arm64.tar.gz` (Apple Silicon) albo `darwin_x64`;
`brew install gitleaks` instaluje najnowszą wersję, nie przypiętą.

Włączenie hooka w repozytorium:

```bash
git config core.hooksPath .githooks
```

Od teraz `git commit` ze znalezionym sekretem zostanie zablokowany. Hook blokuje też commit,
gdy gitleaks nie jest zainstalowany albo ma inną wersję.

### Ręczne skanowanie całej historii

```bash
gitleaks git --redact --verbose .
```

## Wyciek sekretu — co robić

1. **Natychmiast unieważnij klucz i wygeneruj nowy** u dostawcy (Google AI Studio, Linear, GitHub, Anthropic).
2. Dopiero potem usuń go z kodu i zaktualizuj sekret w GitHub (Settings → Secrets and variables → Actions).
3. Nie polegaj na przepisaniu historii — publiczne repozytorium mogło zostać już skopiowane.
   Wypchnięty sekret traktuj jako skompromitowany, nawet jeśli commit został usunięty.

## Uruchomienie w development na serwerze

Aplikacja działa w trybie development i nasłuchuje tylko na `localhost`. Wszystkie usługi
(Redis, Ollama, Rails) są dostępne wyłącznie lokalnie na serwerze.

### 1. Usługi (jednorazowo)

Redis z modułem wyszukiwania, osobny dla RAG, tylko na `127.0.0.1:6380`:

```bash
docker run -d --name rag-redis --restart unless-stopped \
  -p 127.0.0.1:6380:6379 -v rag-redis-data:/data \
  redis:8 redis-server --maxmemory-policy noeviction
```

Ollama z modelem embeddingów (nasłuchuje na `127.0.0.1:11434`):

```bash
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama   # instalator pomija ten krok, gdy systemd nie jest w stanie "running"
ollama pull bge-m3
```

### 2. Kod i zależności

```bash
git clone <adres-repozytorium>
cd rag-instrukcje
bundle install
```

Instrukcje użytkownika (`docs/user/*.md`) i zbiór ewaluacyjny (`spec/rag/golden.yml`) są
poufne i nie ma ich w repozytorium (`.gitignore`). Skopiuj je na serwer osobno, np. `scp`.
Wzór zbioru: `spec/rag/golden.example.yml`.

### 3. Zmienne środowiskowe

Aplikacja czyta konfigurację ze zmiennych środowiskowych (bez pliku `.env`). Dopisz je do
`~/.bashrc` na serwerze i nigdy nie commituj wartości:

```bash
export RAG_GEMINI_API_KEY="..."            # opcjonalnie; bez klucza API zwraca tylko źródła
# export RAG_REDIS_URL="redis://localhost:6380/0"   # domyślna wartość
# export OLLAMA_URL="http://localhost:11434"        # domyślna wartość
```

Fragmenty instrukcji i pytania trafiają do Gemini. Na darmowym tierze Google może
wykorzystywać te dane do ulepszania modeli.

### 4. Indeks i serwer

```bash
bin/rails rag:doctor   # Redis, wymiar embeddingu 1024, Gemini
bin/rails rag:index    # indeksuje zmienione pliki docs/user/
bin/rails rag:eval     # Recall@3 i MRR na spec/rag/golden.yml
bin/rails server       # port 3000, tylko localhost
```

Serwer działa, dopóki otwarta jest sesja terminala; do pracy w tle użyj np. `tmux`.
Dostęp z własnego komputera: sekcja „Dostęp do API”.

## Dostęp do API

Aplikacja na serwerze to wyłącznie API (bez widoków). Działa w trybie development i
nasłuchuje tylko na `localhost`; z internetu dostępne jest wyłącznie SSH. Dostęp do API
uzyskuje się przez tunel SSH.

### 1. Otwarcie tunelu

Na swoim komputerze otwórz tunel SSH mapujący lokalny port `3001` na port `3000` na
serwerze (port `3001`, bo `3000` zwykle zajmuje lokalna aplikacja Rails):

```bash
ssh -N -L 3001:localhost:3000 <użytkownik>@<serwer>
```

### 2. Sprawdzenie tunelu

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3001/up
```

Powinno zwrócić `200`.

### 3. Zapytanie do API

`POST /api/ask` przyjmuje `{"question": "..."}` i zwraca JSON z wyszukaną dokumentacją oraz
odpowiedzią Gemini (jeśli włączona):

```bash
curl -s -X POST http://localhost:3001/api/ask \
  -H 'Content-Type: application/json' \
  -d '{"question":"..."}'
```

Pola odpowiedzi:

* `status` — `ok`, `not_in_docs`, `no_results`, `disabled`, `rate_limited` albo `error`.
* `answer` — odpowiedź Gemini w Markdown albo `null`.
* `finish_reason` — powód zakończenia generowania (`STOP`, `MAX_TOKENS`, ...) albo `null`.
* `sources` — dopasowane sekcje dokumentacji (obecne też przy `disabled` i `rate_limited`).
* `suggestions` — tytuły najbliższych instrukcji, tylko przy `no_results`.

Kody HTTP: `200` dla `ok`/`not_in_docs`/`no_results`/`disabled`, `429` dla `rate_limited`,
`503` dla `error` oraz niedostępności Redis/Ollama, `400` dla pustego lub brakującego
`question`.

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
