# Wyszukiwarka instrukcji aplikacji: Rails + Redis + Ollama (bge-m3) + opcjonalnie Gemini

Stan na 15.09.2026. Fakty ze źródeł są oznaczone w sekcji 2. Pozostałe elementy to decyzje projektowe lub założenia i są tak nazwane.

---

## 0. Zakres

Użytkownik wpisuje pytanie. System zwraca **dosłowne sekcje instrukcji** (do 3 różnych instrukcji) i link do pełnej instrukcji. Opcjonalnie, nad wynikami, **odpowiedź Gemini** wygenerowana wyłącznie z tych sekcji (sekcja 13).

Wyszukiwarka działa bez Gemini. Brak klucza, wyczerpany limit lub błąd API nie wpływa na wyniki wyszukiwania.

| Element | Rola |
|---|---|
| Pliki Markdown w `docs/user` | Źródło prawdy, wersjonowane w Git |
| bge-m3 w Ollama | Zamiana tekstu na wektory — wyszukiwanie po znaczeniu |
| Redis (Query Engine) | Indeks wektorowy, wyszukiwanie KNN |
| Rails | Indeksowanie, wyszukiwanie, widoki, lint dokumentacji |
| Gemini API (opcjonalnie) | Odpowiedź na pytanie na podstawie znalezionych sekcji |

**Dlaczego LLM przez API, a nie lokalnie:** na docelowej maszynie (8 vCPU Haswell, bez GPU) lokalne generowanie szacowano na ok. 1,5–5 min. Wyszukiwanie lokalne to szacunkowo ok. 1–2 s (zmierz: `rag:doctor`, `rag:search`). Gemini działa na infrastrukturze Google.

**Decyzje wynikające z dokumentacji (zachowane z poprzednich wersji):**

| Decyzja | Powód (fakt ze źródła) |
|---|---|
| Natywne `/api/embed`, `Net::HTTP`, bez gemu klienta | Wystarcza jeden endpoint |
| `truncate: false` | `/api/embed` domyślnie obcina za długie wejście po cichu |
| Indeks FLAT | Redis wskazuje FLAT dla zbiorów < 1M wektorów (wynik dokładny) |
| `LIMIT 0 k` w `FT.SEARCH` | Domyślny `LIMIT` to 10 |
| `Rag.redis` / `Rag.ollama` zamiast stałych w initializerze | Initializer nie powinien autoloadować klas z `app/` |

---

## 1. Założenia

1. Instrukcje dotyczą aplikacji Rails 7.1+, która hostuje też wyszukiwarkę.
2. Teksty interfejsu są w `config/locales/*.yml` (warunek działania `docs:lint`).
3. Instrukcje i pytania są po polsku.
4. Redis 8+ z modułem wyszukiwania (lub Redis Stack), protokół RESP2 (nie ustawiaj `protocol: 3`).
5. Ollama działa na tej samej maszynie (domyślnie nasłuchuje na 127.0.0.1).
6. Liczba fragmentów dokumentacji < 1M.
7. Gemini na free tierze jest używane **wyłącznie lokalnie przez Ciebie** (sekcja 13.1). Aplikacja z Gemini nie jest udostępniana innym osobom.
8. Turbo (domyślne w Rails 7) ładuje odpowiedź Gemini w tle. Bez Turbo odpowiedź otwiera się po kliknięciu linku.

---

## 2. Zweryfikowane fakty i źródła

| Fakt | Źródło |
|---|---|
| `/api/embed`: `input` string lub tablica; `truncate` domyślnie `true`; odpowiedź `embeddings` | https://docs.ollama.com/api/embed.md |
| bge-m3: 1024 wymiary, wejście do 8192 tokenów, 100+ języków, licencja MIT; w Ollama ok. 1,2 GB | https://zilliz.com/ai-models/bge-m3 , https://www.morphllm.com/ollama-embedding-models |
| Redis: `FT.CREATE ... VECTOR FLAT 6 TYPE FLOAT32 DIM n DISTANCE_METRIC COSINE`; KNN wymaga `DIALECT >= 2`; domyślny `LIMIT` 10; dystans COSINE w zakresie 0–2, mniejszy = bliżej; rozmiar bloba musi pasować do DIM i typu | https://redis.io/docs/latest/develop/ai/search-and-query/vectors/ |
| Ollama zwalnia model po 5 min (`keep_alive`); `OLLAMA_KEEP_ALIVE=-1` trzyma go stale; parametr w żądaniu nadpisuje zmienną środowiskową | https://cohorte.co/blog/ollama-for-ai-model-serving |
| Zmienne środowiskowe Ollama na Linuksie (systemd): `systemctl edit ollama.service`, sekcja `[Service]`, `Environment=...`, potem `daemon-reload` i `restart` | https://github.com/ollama/ollama/blob/main/docs/faq.md |
| Diátaxis: tutoriale, how-to, reference, explanation (Daniele Procida) | https://github.com/evildmp/diataxis-documentation-framework |
| Gemini REST: `POST .../v1beta/models/{model}:generateContent`, nagłówek `x-goog-api-key`, `systemInstruction`, `generationConfig.maxOutputTokens`, `thinkingConfig.thinkingLevel`; odpowiedź `candidates[].content.parts[].text`, `finishReason`. Dla modeli 3.x zalecane domyślne `temperature`. Dokumentacja oznacza ten endpoint jako „Generate Content API (Legacy)” | https://ai.google.dev/gemini-api/docs/generate-content/text-generation |
| Model `gemini-3.1-flash-lite` (wersja stabilna), wejście do 1 048 576 tokenów, wyjście do 65 536 | https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-lite |
| Limity: RPM, TPM, RPD; liczone na projekt, nie na klucz; RPD odnawia się o północy czasu pacyficznego; konkretne wartości tylko w AI Studio; nie są gwarantowane | https://ai.google.dev/gemini-api/docs/rate-limits |
| Free tier: warunek „aktywny projekt”, bez daty wygaśnięcia; nieudane zapytania liczą się do limitu; płatny tier: przedpłata min. $5, kredyty ważne 12 miesięcy, przy saldzie $0 API przestaje działać | https://ai.google.dev/gemini-api/docs/billing |
| Ponawiać tylko 429, 408, 5xx (z rosnącym odstępem), nie 400/403; modele 3.x mają thinking domyślnie włączony (większe opóźnienie i zużycie tokenów) | https://ai.google.dev/gemini-api/docs/troubleshooting |
| Warunki: 18+; aplikacje dla użytkowników w EOG, CH, UK tylko na płatnych usługach; nie wysyłać danych osobowych do darmowych usług; w EOG zasady wykorzystania danych z płatnych usług obowiązują też dla darmowych | https://ai.google.dev/gemini-api/terms |
| Monitoring nadużyć: automatyczny i ręczny; prompty i odpowiedzi przechowywane 55 dni; możliwe ograniczenie, zawieszenie lub zamknięcie dostępu | https://ai.google.dev/gemini-api/docs/usage-policies |

---

## 3. Przepływ

**Indeksowanie** (`bin/rails rag:index`, po każdym deployu):
1. `docs/user/**/*.md` (bez plików `_*.md`), porównanie SHA-256 z rejestrem w Redis — niezmienione pliki są pomijane.
2. `MarkdownChunker`: dokument ≤ 1500 znaków → 1 fragment; dłuższy → podział po `## `.
3. Wektoryzowany jest tekst: ścieżka nagłówków + `questions` z front matter (tylko pierwszy fragment) + treść.
4. W Redis zapisywane są: `source`, `title`, `heading`, `content` (sama treść do wyświetlenia), `embedding`.

**Wyszukiwanie** (`GET /pomoc?q=...`):
1. Embedding pytania (bge-m3).
2. KNN w Redis: `RAG_CANDIDATES` (10) najbliższych fragmentów.
3. Najlepsza sekcja z każdego pliku, filtr `RAG_MAX_DISTANCE`, maksymalnie `RAG_RESULTS` (3).
4. Są wyniki → pierwsza sekcja rozwinięta, pozostałe zwinięte, link do pełnej instrukcji.
5. Brak wyników → komunikat + tytuły `RAG_SUGGESTIONS` (3) najbliższych instrukcji, bez treści.

**Odpowiedź Gemini** (`GET /pomoc/odpowiedz?q=...`, ładowana osobno przez Turbo Frame):
1. Tylko gdy są wyniki wyszukiwania i Gemini jest włączone (`Rag::Answer.enabled?`).
2. Do Gemini idą: prompt systemowy, ponumerowane sekcje z wyszukiwania, pytanie.
3. Model ma odpowiadać tylko z sekcji, cytować `[n]`, a przy braku informacji zwrócić ustalone zdanie.
4. Wynik: odpowiedź + lista źródeł `[n]` z linkami. Przy 429 lub błędzie: komunikat, wyniki wyszukiwania zostają.

---

## 4. Instalacja Ollama i modelu embeddingów

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull bge-m3
```

Model trzymany stale w pamięci (ok. 1,2 GB), żeby pierwsze pytanie po przerwie nie czekało na ładowanie:

```bash
sudo systemctl edit ollama.service
# w edytorze:
# [Service]
# Environment="OLLAMA_KEEP_ALIVE=-1"
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Kod nie wysyła `keep_alive` w żądaniu, chyba że ustawisz `RAG_KEEP_ALIVE`; wtedy wartość z żądania nadpisuje ustawienie serwera.

Weryfikacja:

```bash
curl -s http://localhost:11434/api/embed \
  -d '{"model":"bge-m3","input":["test"],"truncate":false}' \
  | ruby -rjson -e 'puts JSON.parse($stdin.read)["embeddings"][0].size'   # oczekiwane: 1024
ollama ps   # po pierwszym zapytaniu: bge-m3, 100% CPU, UNTIL: Forever
```

Jeśli wcześniej pobrano Bieliki, zwolnij dysk: `ollama rm <nazwa_modelu>` (lista: `ollama list`).

### 4.1 Klucz Gemini (opcjonalnie)

1. Klucz API utwórz w AI Studio: https://aistudio.google.com/apikey
2. Swoje limity dla modelu sprawdź na: https://aistudio.google.com/rate-limit
3. Ustaw klucz w zmiennej środowiskowej, poza repozytorium:
   ```bash
   export RAG_GEMINI_API_KEY="..."   # nie commituj; dodaj plik z kluczem do .gitignore, jeśli używasz np. dotenv
   ```
4. `bin/rails rag:doctor` wykona jedno testowe zapytanie do Gemini (zużywa 1 zapytanie z limitu).

Weryfikacja bez Rails:

```bash
curl -s "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent" \
  -H "x-goog-api-key: $RAG_GEMINI_API_KEY" -H 'Content-Type: application/json' -X POST \
  -d '{"contents":[{"parts":[{"text":"Odpowiedz jednym słowem: działa"}]}]}'
```

---

## 5. Redis — weryfikacja

```bash
redis-cli INFO server | grep redis_version
redis-cli FT._LIST                      # "unknown command" = brak modułu wyszukiwania
redis-cli CONFIG GET maxmemory-policy   # allkeys-* może usuwać klucze indeksu
```

---

## 6. Pliki

```
app/lib/rag.rb                      # Rag.redis, Rag.ollama
app/lib/rag/ollama_client.rb        # POST /api/embed (Net::HTTP)
app/lib/rag/embedder.rb             # wsady + kontrola wymiaru
app/lib/rag/index.rb                # FT.CREATE (FLAT, 1024, COSINE), id_for, usuwanie po źródle
app/lib/rag/markdown_chunker.rb     # front matter, questions, podział po nagłówkach
app/lib/rag/indexer.rb              # synchronizacja docs/user -> Redis po SHA-256
app/lib/rag/retriever.rb            # KNN + LIMIT + parsowanie RESP2
app/lib/rag/search.rb               # najlepsza sekcja na plik, próg, podpowiedzi
app/lib/rag/gemini_client.rb        # POST generateContent (Net::HTTP), ponawianie 429/408/5xx
app/lib/rag/answer.rb               # prompt, statusy, enabled?, kontrola odwołań [n]
app/lib/docs_lint.rb                # zgodność instrukcji z config/locales
app/controllers/search_controller.rb  # GET /pomoc (HTML i JSON)
app/controllers/docs_controller.rb    # GET /pomoc/:id (pełna instrukcja)
app/controllers/answers_controller.rb # GET /pomoc/odpowiedz (odpowiedź Gemini)
app/helpers/docs_helper.rb          # render Markdown (redcarpet, escape_html)
app/views/search/index.html.erb
app/views/docs/show.html.erb
app/views/answers/show.html.erb
config/routes_snippet.rb            # trasy do wklejenia w config/routes.rb
lib/tasks/rag.rake                  # create_index, index, reindex, doctor, search, eval, ask, eval_answers
lib/tasks/docs.rake                 # docs:lint
docs/user/_szablon.md               # szablon instrukcji (pomijany przy indeksowaniu)
spec/rag/golden.yml                 # zbiór ewaluacyjny
test/rag_standalone/                # testy jednostkowe bez Rails/Redis/Ollama
```

---

## 7. Integracja z aplikacją Rails

Gemfile:

```ruby
gem "redis", "~> 5.0"
gem "redcarpet", "~> 3.6"
```

Trasy (`config/routes.rb`):

```ruby
get "/pomoc", to: "search#index", as: :search
get "/pomoc/odpowiedz", to: "answers#show", as: :answer
get "/pomoc/:id", to: "docs#show", as: :doc, constraints: { id: /[0-9a-f]{16}/ }
```

- **Autoryzacja:** kontrolery dziedziczą z `ApplicationController`, więc obowiązują jego filtry (logowanie, autoryzacja). Dopasuj, kto ma dostęp do pomocy.
- **Widoki:** celowo bez stylów. `<details>` daje zwijanie bez JavaScriptu. Dostosuj do layoutu aplikacji.
- **JSON:** `GET /pomoc.json?q=...` → `{"results":[...],"suggestions":[...]}`.

Zmienne środowiskowe (wszystkie opcjonalne):

| Zmienna | Domyślnie | Uwaga |
|---|---|---|
| `RAG_REDIS_URL` | `redis://localhost:6379/0` | |
| `OLLAMA_URL` | `http://localhost:11434` | |
| `RAG_OLLAMA_TIMEOUT` | `120` | sekundy; dotyczy też indeksowania wsadów |
| `RAG_KEEP_ALIVE` | brak (ustawienie serwera) | np. `30m`; nadpisuje `OLLAMA_KEEP_ALIVE` |
| `RAG_EMBEDDING_MODEL` | `bge-m3` | zmiana = `rag:reindex` |
| `RAG_EMBEDDING_DIM` | `1024` | musi odpowiadać modelowi |
| `RAG_EMBEDDING_BATCH` | `16` | wielkość wsadu przy indeksowaniu |
| `RAG_MAX_DISTANCE` | `0.5` | **placeholder** — skalibruj (sekcja 11) |
| `RAG_CANDIDATES` | `10` | fragmenty pobierane z Redis przed wyborem sekcji na plik |
| `RAG_RESULTS` | `3` | maksymalna liczba instrukcji w wynikach |
| `RAG_SUGGESTIONS` | `3` | tytuły przy braku wyników |
| `RAG_CHUNK_MAX_CHARS` | `1500` | zmiana = `rag:reindex` |
| `RAG_DOCS_GLOB` | `docs/user/**/*.md` | |
| `RAG_GEMINI_API_KEY` | brak = Gemini wyłączone | nie commituj |
| `RAG_GEMINI_MODEL` | `gemini-3.1-flash-lite` | sprawdź w AI Studio, czy model ma limit na free tierze |
| `RAG_GEMINI_MAX_OUTPUT_TOKENS` | `2048` | przy ucięciu `finish_reason=MAX_TOKENS` |
| `RAG_GEMINI_THINKING_LEVEL` | brak (domyślne modelu) | np. `low`; niższy poziom = mniejsze opóźnienie |
| `RAG_GEMINI_TIMEOUT` | `60` | sekundy |
| `RAG_GEMINI_DELAY_SECONDS` | `6` | przerwa między zapytaniami w `rag:eval_answers`; dopasuj do RPM |
| `RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT` | brak | `1` tylko z kluczem płatnym (sekcja 13.1) |

---

## 8. Uruchomienie

```bash
bin/rails rag:doctor                          # Redis, wymiar, czas embeddingu (przebieg 1 i 2)
bin/rails docs:lint                           # zgodność instrukcji z kodem
bin/rails rag:index                           # indeksowanie przyrostowe
bin/rails rag:search Q="jak poprawić fakturę" # wyniki, dystanse, czas
bin/rails rag:eval                            # Recall@3, MRR, dystanse do kalibracji progu
bin/rails rag:ask Q="czy mogę usunąć wysłaną fakturę"  # wyszukiwanie + odpowiedź Gemini, czasy, tokeny
bin/rails rag:eval_answers                    # odpowiedzi Gemini dla golden.yml -> tmp/rag_answers_*.md
bin/rails server                              # w development domyślnie tylko localhost; nie wystawiaj na zewnątrz
```

Testy jednostkowe (bez Rails, Redis i Ollama; Ruby ≥ 3.0):

```bash
ruby -Itest/rag_standalone/stubs test/rag_standalone/run_test.rb
```

Obejmują: chunker (w tym `questions` tylko w tekście wektoryzowanym), parsowanie RESP2 i format FLOAT32, indeksowanie przyrostowe i usuwanie plików, wybór najlepszej sekcji na plik, próg, podpowiedzi, `LIMIT`, klienta Ollama (`truncate: false`, brak `keep_alive`, błąd HTTP), `DocsLint`, klienta Gemini (format żądania, klucz tylko w nagłówku, pomijanie części `thought`, ponawianie 429/503, brak ponawiania 400) oraz `Rag::Answer` (włączanie tylko w development, brak wywołania API bez wyników, statusy, kontrola `[n]`).

**Nie obejmują:** kontrolerów, widoków, helpera Markdown (redcarpet) ani integracji z prawdziwym Redis, Ollama i Gemini. Pierwsze uruchomienie w Twoim środowisku: `rag:doctor`, potem `rag:search`, potem `rag:ask`.

---

## 9. Co widzi użytkownik

| Sytuacja | Zachowanie |
|---|---|
| Pytanie konkretne lub potoczne | Najlepsza sekcja rozwinięta, 2 kolejne instrukcje zwinięte, link do pełnej instrukcji |
| Pytanie ogólne („faktury”) | Kilka instrukcji z tematu; lista działa jak spis treści |
| Pytanie złożone (dwie czynności) | Jeden wektor dla całego pytania; obie instrukcje mogą być w wynikach, ale jedna może wypaść — sprawdź w `rag:eval` |
| Pytanie tak/nie | Sekcja z ograniczeniem; odpowiedź musi być w instrukcji zdaniem twierdzącym (sekcja 10.4, reguła 7) |
| Dopytanie („a jeśli już wysłałem?”) | Brak kontekstu poprzedniego pytania; każde pytanie musi być pełne |
| Temat spoza dokumentacji | „Nie znaleziono instrukcji…” + tytuły najbliższych tematów |
| Ollama lub Redis niedostępne | „Wyszukiwarka jest chwilowo niedostępna.” (HTTP 503) |
| Gemini włączone, są wyniki | Nad wynikami pojawia się odpowiedź AI z listą źródeł `[n]`; wyniki wyszukiwania widoczne od razu |
| Gemini: wyczerpany limit (429) | Komunikat o limicie; wyniki wyszukiwania zostają |
| Gemini: brak odpowiedzi w sekcjach | „Asystent AI nie znalazł odpowiedzi w dokumentacji.” |

---

## 10. Jak pisać instrukcje, żeby były zrozumiałe i zgodne z prawdą

### 10.1 Zasada

Każde twierdzenie w instrukcji musi dać się sprawdzić w kodzie lub teście:
1. fakty zbierasz z kodu deterministycznie (10.2),
2. człowiek pisze instrukcję według szablonu,
3. test systemowy weryfikuje przepływ,
4. `docs:lint` weryfikuje etykiety,
5. dopiero wtedy `rag:index`.

Bez LLM użytkownik czyta dokładnie to, co napisałeś — jakość wyszukiwarki to jakość instrukcji.

### 10.2 Źródła faktów w aplikacji Rails

| Fakt w instrukcji | Źródło prawdy | Jak wyciągnąć |
|---|---|---|
| Jakie ekrany i akcje istnieją | routing | `bin/rails routes` (np. `bin/rails routes -c invoices`) |
| Dosłowne nazwy przycisków, menu, pól, komunikatów | `config/locales/pl.yml` | słownik etykiet do instrukcji |
| Reguły pól | walidacje | `grep -rn "validates" app/models` |
| Statusy | `enum` + tłumaczenia | `grep -rn "enum " app/models` |
| Komunikaty po akcji | kontrolery | `grep -rnE "notice:\|alert:\|flash\[" app/controllers` |
| Kto może wykonać czynność | warstwa autoryzacji | zależy od biblioteki (sekcja 14) |
| Że przepływ działa | testy systemowe | `test/system` lub `spec/system` |

### 10.3 Struktura

Z czterech typów dokumentacji Diátaxis zacznij od dwóch:
- **how-to:** jeden plik = jedna czynność (`docs/user/faktury/wystawianie-faktury-korygujacej.md`),
- **reference:** słowniki statusów, pól i komunikatów błędów (`docs/user/referencja/statusy-faktur.md`).

### 10.4 Reguły pisania

1. Tytuł = cel użytkownika jako czynność, nie nazwa ekranu ani klasy.
2. Jeden plik = jedna czynność, najlepiej ≤ 1500 znaków (cała instrukcja w jednym wyniku).
3. Sekcje w kolejności: Wymagania → Kroki → Wynik → Błędy i rozwiązania.
4. Kroki: lista numerowana, tryb rozkazujący, jedna akcja na krok.
5. `**pogrubienie**` = wyłącznie dosłowna etykieta z `config/locales`.
6. Po krokach opisz wynik: dosłowny komunikat, zmiana statusu.
7. **Ograniczenia zdaniem twierdzącym na początku sekcji Wymagania**, np. „Wysłanej faktury nie można usunąć. Wystaw fakturę korygującą.” Bez LLM to jedyny sposób, żeby pytanie tak/nie dostało odpowiedź wprost.
8. Bez odwołań „jak wyżej”, „poniżej” — sekcja bywa wyświetlana sama.
9. Bez nazw technicznych (modele, tabele, endpointy).
10. Bez danych osobowych w przykładach.
11. Front matter: `title`, `audience`, `verified_by`, `last_verified`, opcjonalnie `questions`.

### 10.5 Pole `questions`

```yaml
questions:
  - Jak poprawić błędną fakturę?
  - Pomyliłem kwotę na fakturze, co zrobić?
```

- Pytania dołączane są do tekstu wektoryzowanego pierwszego fragmentu i nie są wyświetlane.
- Cel: zbliżyć wektor instrukcji do sformułowań użytkowników, które różnią się od tytułu.
- To decyzja projektowa, nie fakt: skuteczność sprawdź w `rag:eval`, porównując wyniki przed i po dodaniu pytań.
- Źródło pytań: zgłoszenia do supportu, pytania zadawane przez użytkowników, wyniki `rag:eval` z pudłami.
- Nie kopiuj tych samych pytań do `golden.yml` — ewaluacja wyszłaby zawyżona.

### 10.6 Automatyczna kontrola zgodności z kodem

**`bin/rails docs:lint`** zgłasza błąd, gdy:
- `**etykieta**` nie występuje w `config/locales/**/*.yml` dla `pl` (z obsługą `%{zmienna}`),
- brakuje pola front matter lub `last_verified` nie jest datą,
- `verified_by` wskazuje nieistniejący plik,
- `questions` nie jest listą niepustych tekstów.

Ostrzega przy „jak wyżej” itp. („powyżej” da fałszywe ostrzeżenie np. w „powyżej 100 zł”). Etykiety wpisane na sztywno w widokach zostaną zgłoszone jako brakujące — przenieś je do plików tłumaczeń.

**Test systemowy na każdą instrukcję how-to** używa tych samych kluczy tłumaczeń co widok. Schemat (ścieżki, klucze i logowanie przykładowe):

```ruby
# test/system/docs/wystawianie_faktury_korygujacej_test.rb
require "application_system_test_case"

module Docs
  class WystawianieFakturyKorygujacejTest < ApplicationSystemTestCase
    # Weryfikuje: docs/user/faktury/wystawianie-faktury-korygujacej.md
    test "kroki z instrukcji prowadzą do opisanego wyniku" do
      # zaloguj użytkownika o roli z pola audience (zależne od Twojej autentykacji)
      visit invoices_path
      click_on I18n.t("invoices.show.correct")
      fill_in I18n.t("activerecord.attributes.correction.reason"), with: "Błędna ilość"
      click_on I18n.t("corrections.form.submit")
      assert_text I18n.t("corrections.create.success")
    end
  end
end
```

CI: `bin/rails docs:lint && bin/rails test test/system/docs`. Po deployu: `bin/rails rag:index`.

---

## 11. Ewaluacja i kalibracja progu

1. Zbierz 20–50 pytań w języku użytkowników: potoczne, ogólne, złożone (dwa pliki w `expected_sources`), tak/nie, z literówkami. Dodaj 5–10 pytań spoza zakresu z `expected_sources: []`.
2. `bin/rails rag:eval` wypisuje:
   - Recall@3 i MRR na poziomie plików,
   - dystans najlepszego wyniku dla każdego pytania,
   - zakres dystansów dla pytań w zakresie i spoza zakresu.
3. `RAG_MAX_DISTANCE`: wartość między `max` dystansów w zakresie a `min` dystansów spoza zakresu. Jeśli zakresy się nakładają, wybierz, który błąd jest mniej szkodliwy:
   - próg niższy → więcej „nie znaleziono” dla trafnych pytań,
   - próg wyższy → nietrafne instrukcje przy pytaniach spoza zakresu.
4. Powtarzaj po zmianie `RAG_CHUNK_MAX_CHARS`, modelu embeddingów, dodaniu `questions` lub dużych zmianach w dokumentacji.

---

## 12. Znane ograniczenia

- **Pytania złożone i dopytania:** brak łączenia instrukcji i brak kontekstu rozmowy (sekcja 9).
- **Literówki:** nie wiem, jak bge-m3 radzi sobie z polskimi literówkami — zmierz w `rag:eval`.
- **Długie instrukcje:** `questions` trafiają tylko do pierwszego fragmentu. Dopasowanie po pytaniu pokaże pierwszą sekcję pliku, niekoniecznie tę z odpowiedzią. Stąd reguła 10.4.2: krótkie pliki.
- **Mało różnych plików w wynikach:** jeśli jeden plik ma wiele fragmentów, 10 kandydatów może dać mniej niż 3 różne instrukcje. Zwiększ `RAG_CANDIDATES`.
- **Chunker:** podział po akapitach może rozciąć blok kodu zawierający pustą linię.
- **Brak testów integracyjnych** kontrolerów, widoków i helpera Markdown (sekcja 8).
- **Gemini — zgodność z instrukcjami:** odpowiedź może zawierać błąd mimo promptu. Kontrola `[n]` sprawdza tylko format odwołań, nie poprawność; oceniaj ręcznie w `tmp/rag_answers_*.md`.
- **Gemini — endpoint „Legacy”:** dokumentacja oznacza `generateContent` jako Generate Content API (Legacy) i opisuje nowsze Interactions API. Endpoint jest udokumentowany i działa; migracja może być kiedyś wymagana.
- **Gemini — druga wektoryzacja pytania:** odpowiedź AI ładowana osobnym żądaniem powtarza wyszukiwanie (dodatkowy embedding, szacunkowo ok. 1–2 s).

---

## 13. Gemini

### 13.1 Warunki (stan na 15.09.2026; nie jestem prawnikiem)

| Sytuacja | Free tier |
|---|---|
| Tylko Ty, lokalnie lub na swoim serwerze | Zgodne z warunkami |
| Ktokolwiek inny w Polsce/EOG ma dostęp do aplikacji z Gemini (link, ngrok, konto testowe) | Niezgodne — wymagany płatny tier |

Zabezpieczenia w kodzie:
- `Rag::Answer.enabled?` zwraca `true` tylko przy ustawionym kluczu **i** `Rails.env == "development"`. Poza development wymaga świadomego `RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT=1`.
- `bin/rails server` w development nasłuchuje domyślnie tylko na localhost.

Nie wysyłaj danych osobowych (warunki darmowych usług). Pytania w `golden.yml` i własne testy pisz bez nich.

### 13.2 Plan testów z Gemini

1. `bin/rails rag:doctor` — sprawdzenie klucza i modelu (1 zapytanie).
2. `bin/rails rag:ask Q="..."` dla kilku pytań — czas, tokeny, status, jakość po polsku.
3. `bin/rails rag:eval_answers` — odpowiedzi dla całego `golden.yml` do pliku. Ustaw `RAG_GEMINI_DELAY_SECONDS` = 60 / RPM z AI Studio (np. RPM 10 → 6 s). Zadanie przerywa się przy 429.
4. W pliku `tmp/rag_answers_*.md` oceń ręcznie każdą odpowiedź: poprawna / częściowo / błędna / zmyślona treść.
5. Porównaj z samym wyszukiwaniem (sekcja 9): czy odpowiedź AI daje wartość przy pytaniach tak/nie, złożonych i ogólnych.
6. Jeśli odpowiedzi są za wolne: `RAG_GEMINI_THINKING_LEVEL=low` i ponowny pomiar w `rag:ask`.

### 13.3 Przejście na płatny tier (gdy aplikacja ma trafić do innych osób)

1. AI Studio → Set up billing → przedpłata (min. $5).
2. Bez automatycznego doładowania: przy saldzie $0 API przestaje działać, więc koszt jest ograniczony do wpłaty.
3. Opcjonalnie limit wydatków projektu na stronie Spend (funkcja eksperymentalna, możliwe przekroczenie w ok. 10-minutowym oknie).
4. Klucz z płatnego projektu w `RAG_GEMINI_API_KEY` + `RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT=1` na serwerze.
5. Przed udostępnieniem użytkownikom: logowanie w aplikacji, limit pytań na użytkownika i zasady ochrony danych (konsultacja z inspektorem ochrony danych).

---

## 14. Potrzebny kontekst

1. Czy instrukcje dotyczą tej samej aplikacji Rails?
2. Czy teksty interfejsu są w `config/locales`, czy wpisane w widokach?
3. Jaka biblioteka autoryzacji i kto ma mieć dostęp do `/pomoc`?
4. Minitest czy RSpec dla testów systemowych?
5. Czy Rails, Postgres i Redis działają na tej samej VM co Ollama (dostępne ok. 13 GiB RAM)?
6. Twoje limity dla `gemini-3.1-flash-lite` z https://aistudio.google.com/rate-limit (RPM, RPD) — do ustawienia `RAG_GEMINI_DELAY_SECONDS`.
