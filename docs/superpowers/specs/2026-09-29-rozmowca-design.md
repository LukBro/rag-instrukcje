# Rozmówca przy braku wyników: small talk i pytania spoza instrukcji

Zgłoszenie: [BRO-73](https://linear.app/browarek/issue/BRO-73/rozmowca-przy-braku-wynikow-small-talk-i-pytania-spoza-instrukcji)
Data: 2026-09-29

## Problem

Każde wejście, dla którego wyszukiwarka nie znalazła instrukcji poniżej progu `RAG_MAX_DISTANCE`,
kończy się statusem `no_results` bez wywołania modelu. Klient pokazuje wtedy stały tekst „Nie mam
instrukcji na ten temat. Najbliższe tematy: …”. Dotyczy to także zwykłej rozmowy. Sonda
2026-09-29, dystans najbliższej instrukcji:

| wiadomość | dystans | wynik |
| --- | --- | --- |
| „siemanko, co słychać” | 0,65 | `no_results` + przypadkowe „najbliższe tematy” |
| „co tam u ciebie?” | 0,58 | j.w. |
| „dzięki, pomogło!” | 0,59 | j.w. |
| „w czym możesz mi pomóc?” | 0,51 | j.w. |
| „jestem tu nowy, nie wiem od czego zacząć” | 0,46 | j.w. |

Czat brzmi jak wyszukiwarka, nie jak pomocnik.

## Rozstrzygnięcia

- **Rozmówca działa tylko na ścieżce `no_results`.** Small talk zawsze ląduje poza progiem, więc
  osobny klasyfikator intencji dla każdego pytania nie jest potrzebny. Zwykłe pytania nie zmieniają
  czasu ani kosztu.
- **Rozmówca nie zna treści instrukcji, tylko ich tytuły.** Nigdy nie opisuje, jak coś zrobić;
  może wyłącznie wskazać tematy z listy. Reguła „odpowiadaj tylko na podstawie fragmentów”
  w `Answer::SYSTEM_PROMPT` zostaje nietknięta.
- **Ton:** ciepły, rzeczowy, na „Ty”, 1–3 zdania, bez emoji (wybór właściciela).
- **`not_in_docs` bez zmian w API** — bez drugiego wywołania modelu; łagodniejszy tekst po stronie
  klienta.
- **Reguła „kolejny krok” — sprawdzona i odrzucona.** Planowana jako jedno zdanie „Następnie
  możesz…” w `Answer::SYSTEM_PROMPT`, gdy inny podany fragment opisuje czynność wykonywaną zaraz
  potem. Trzy wersje reguły zmierzone `rag:eval_answers`: rozkład statusów bez zmian, ale mniej
  więcej połowa zdań była szumem — powtarzała odpowiedź, proponowała cofnięcie („usunąć zadanie” po
  jego odhaczeniu) albo czynność sprzeczną z pytaniem — a ostatnia wersja zamieniła jedną poprawną
  odpowiedź na odmowę. Model nie trzyma się zakazu proponowania kroków z tego samego fragmentu.
  `Answer::SYSTEM_PROMPT` zostaje bez zmian względem BRO-27. Deterministyczna alternatywa po
  stronie klienta: pozostałe źródła odpowiedzi jako „Zobacz też”.

Odrzucone: klasyfikator intencji dla każdego pytania i prompt „przewodnika” bez reguły trzymania
się instrukcji — dodatkowe wywołanie modelu przy każdym pytaniu (zmierzony ogon Gemini do 161 s)
i realne ryzyko zmyślonych kroków. Odrzucone też „daj mi znać, przejdziemy dalej”: historia
rozmowy zawiera tylko pytania użytkownika, więc czat nie pamięta, co sam zaproponował.

## Kontrakt `POST /api/ask`

Zmienia się tylko odpowiedź ze statusem `no_results`:

| pole | dziś | po zmianie |
| --- | --- | --- |
| `answer` | `null` | tekst rozmówcy (Markdown) albo `null` przy degradacji |
| `suggestions` | 3 najbliższe instrukcje | 0–3 tematy wybrane przez rozmówcę albo 3 najbliższe przy degradacji |

`suggestions[].distance` może być `null` dla tematu spoza trzech najbliższych. Pozostałe statusy
i kody HTTP bez zmian. Klient, który przy `no_results` ignoruje `answer`, działa jak dotąd.

## Przebieg żądania

1. Jak dziś: opcjonalne przepisanie pytania z historią (BRO-72) i `Search.call`.
2. Znaleziono → `Answer`, bez zmian.
3. Nie znaleziono → `Rag::Conversation` z pytaniem **oryginalnym**, historią pytań i katalogiem
   instrukcji. Wynik: tekst i wybrane tematy. `nil` → dzisiejsze `no_results`.

## Komponenty

| element | rola |
| --- | --- |
| `Rag::Catalog` | lista `{source, title}` wszystkich zaindeksowanych instrukcji, z Redisa |
| `Rag::Conversation` | wiadomość + historia + katalog → `{text, suggestions}` albo `nil` |
| `Rag::GeminiClient#generate` | opcjonalny `response_schema:` → `responseMimeType: application/json` + `responseSchema` |
| `Rag::Ask` | na ścieżce braku wyników woła `Conversation`; `Result` zyskuje `suggestions` |
| `Api::AsksController` | bierze `suggestions` z `Ask::Result` zamiast z `search_result` |

`Search`, `Retriever`, `Embedder`, `QuestionRewriter` — bez zmian.

### Rag::Conversation

- Prompt systemowy (zasady): po polsku, na „Ty”, 1–3 zdania, bez emoji; nigdy nie podaje kroków,
  przycisków, pól ani ustawień; powitanie/podziękowanie → krótka odpowiedź i zaproszenie, bez
  tematów; „w czym pomagasz / od czego zacząć” → obszary aplikacji w jednym zdaniu i do 3 tematów;
  pytanie o aplikację bez instrukcji → wprost „nie mam instrukcji, nie chcę zgadywać” i do 3
  pasujących tematów, jeśli są; pytanie niezwiązane z aplikacją → uprzejma odmowa, bez tematów;
  tematów nie wypisuje w tekście (klient pokazuje je jako przyciski).
- Wiadomość do modelu: ponumerowana lista tytułów instrukcji, poprzednie pytania użytkownika,
  bieżąca wiadomość.
- Odpowiedź w wymuszonym JSON `{"reply": string, "topics": [integer]}`. Kod bierze tylko numery
  z zakresu listy, bez powtórzeń, najwyżej 3.
- `RAG_GEMINI_CONVERSATION_TIMEOUT` domyślnie 10 s, zero ponowień, 256 tokenów wyjścia — jak
  w `QuestionRewriter`: to ulepszenie, które przy niepowodzeniu degraduje się do stanu dzisiejszego.
- Zwraca `nil`, gdy Gemini jest wyłączone, zgłosi błąd lub limit, odpowiedź nie jest poprawnym
  JSON-em albo `reply` jest pusty.

## Obsługa błędów

| sytuacja | zachowanie |
| --- | --- |
| Gemini wyłączone (brak klucza lub środowisko inne niż development) | `answer: null`, 3 najbliższe tematy — jak dziś |
| błąd, limit 429, timeout rozmówcy | j.w., ostrzeżenie w logu |
| odpowiedź nie jest JSON-em lub `reply` pusty | j.w., ostrzeżenie w logu |
| numery tematów spoza listy | pomijane; pozostałe tematy zostają |
| Redis/Ollama niedostępne | bez zmian: 503 z kontrolera |

## Testy i weryfikacja

- `GeminiClient`: `response_schema` trafia do `generationConfig`; bez niego żądanie bez zmian.
- `Catalog`: parsowanie odpowiedzi `FT.SEARCH`, jedna pozycja na plik, sortowanie po tytule.
- `Conversation` na atrapie `FakeGemini`: poprawny JSON → tekst i tematy; numery spoza listy
  i duplikaty odrzucone, limit 3; zły JSON, pusty `reply`, błąd, 429, wyłączone Gemini → `nil`;
  w wiadomości do modelu są tytuły, historia i wiadomość.
- `Ask`: brak wyników → `Conversation` dostaje pytanie oryginalne i historię; `nil` → dzisiejsze
  `no_results` z najbliższymi tematami; wyniki znalezione → `Conversation` nie jest wołany.
- Request spec: `no_results` z `answer` i tematami rozmówcy; degradacja bez zmian kontraktu.
- Na żywo: small talk z tabeli wyżej i pytania spoza zakresu z `golden.yml` — żadna odpowiedź nie
  zawiera kroków; small talk bez tematów.
- Reguła „kolejny krok”: `rag:eval_answers` przed i po — wynik w sekcji „Rozstrzygnięcia”
  (odrzucona).

## Klient (palserwis, poza tym repo)

Przy `no_results`: gdy `answer` jest niepusty, pokazać go zamiast stałego tekstu, a `suggestions`
jako klikalne tematy; gdy `null` — jak dotąd. Przy `not_in_docs`: łagodniejszy tekst. Wymagania
dopisane do instrukcji dla palserwis.

## Koszt

Jedno wywołanie Gemini tylko na ścieżce `no_results` (wlicza się do limitów darmowego tieru:
15 zapytań na minutę, 500 dziennie).
