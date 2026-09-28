# Pamięć czatu: pytania doprecyzowujące w /api/ask

Zgłoszenie: [BRO-72](https://linear.app/browarek/issue/BRO-72/pamiec-czatu-pytania-doprecyzowujace-w-apiask)
Data: 2026-09-28

## Problem

Każde pytanie do `POST /api/ask` jest dziś niezależne. Pytanie doprecyzowujące w rodzaju
„a jak to usunąć?” nie zawiera tematu, więc embedding nie ma czego dopasować i żądanie kończy się
statusem `no_results`. Użytkownik musi za każdym razem powtarzać pełny kontekst.

## Czego ten projekt nie robi

Nie dotyka `Answer::SYSTEM_PROMPT`. Prompt został skalibrowany w BRO-27 (fałszywe odmowy, łączenie
kroków z kilku instrukcji) i jest głównym ryzykiem regresji jakości odpowiedzi. Projekt jest tak
ułożony, żeby do `Answer` trafiało pytanie **samodzielne** — takie, jakiego prompt oczekuje dziś.

Poza zakresem: trzymanie stanu rozmowy na serwerze, streaming odpowiedzi, cache odpowiedzi.

## Kontrakt

```
POST /api/ask
{
  "question": "a jak to usunąć?",
  "history": ["jak dodać adres dostawy klienta?"]
}
```

- `history` jest **opcjonalne**: tablica poprzednich **pytań użytkownika**, najstarsze pierwsze.
  Brak pola albo pusta tablica = zachowanie identyczne jak dziś, więc obecny klient nie wymaga
  żadnej zmiany.
- Odpowiedzi asystenta do historii nie wchodzą. Kosztują setki tokenów na turę, a do ustalenia
  tematu pytania wystarczają same pytania.
- Limity: **5 ostatnich pytań**, każde do **500 znaków**. Nadwyżka jest obcinana po cichu, bez
  błędu 400 — klient nie powinien wywracać się na długości historii.
- Format odpowiedzi **bez zmian**: `status`, `answer`, `finish_reason`, `sources`, `suggestions`.

Stan rozmowy trzyma klient. Serwer pozostaje bezstanowy: nic nie przechowuje, nie ma TTL ani cyklu
życia sesji, nie powstaje pytanie o przechowywanie treści rozmów.

## Przebieg żądania

1. `Search.call(question)` — mediana 0,09 s. Jeśli znaleziono cokolwiek poniżej progu
   `RAG_MAX_DISTANCE`, dalej jak dziś. **To jest typowa tura i nie kosztuje nic ponad stan obecny.**
2. Brak wyników **i** niepusta `history` → `Rag::QuestionRewriter` przepisuje pytanie na samodzielne.
3. `Search.call(przepisane)`. Jeśli znaleziono → `Rag::Answer` dostaje pytanie **przepisane**.
4. Nadal nic → `no_results` + `suggestions`, dokładnie jak dziś.

Przepisywanie jest fallbackiem, nie regułą. Powód: to dodatkowe wywołanie Gemini, a zmierzony ogon
latencji Gemini dochodził do 161 s. Płacimy je tylko tam, gdzie dziś i tak zwracamy `no_results`.

## Komponenty

| element | rola | zależności |
| --- | --- | --- |
| `Rag::QuestionRewriter` | historia + pytanie → jedno samodzielne pytanie | `GeminiClient` |
| `Rag::Ask` | orkiestracja kroków 1-4 | `Search`, `QuestionRewriter`, `Answer` |

`Search`, `Retriever`, `Embedder`, `Answer`, `GeminiClient` — bez zmian w zachowaniu.
`Api::AsksController` woła `Rag::Ask` zamiast `Search` + `Answer` i pozostaje cienki.

### Rag::QuestionRewriter

- Własny, krótki prompt systemowy: przepisz ostatnie pytanie na samodzielne, korzystając z
  poprzednich pytań; nie dopisuj informacji, których w nich nie ma; jeśli pytanie jest już
  samodzielne, zwróć je bez zmian; zwróć samo pytanie, bez komentarza.
- `max_output_tokens` 64 — wynikiem jest jedno zdanie.
- `RAG_GEMINI_REWRITE_TIMEOUT`, domyślnie **15 s**, i **jedno** ponowienie, zamiast 90 s i dwóch
  ponowień jak w `Answer`. To wywołanie na kilkadziesiąt tokenów: albo odpowiada szybko, albo nie
  warto na nie czekać.
- Zwraca `nil`, gdy Gemini jest wyłączone, zwróci pustą treść albo zgłosi błąd. `nil` oznacza
  „brak przepisania” i prowadzi prosto do kroku 4, czyli do zachowania sprzed zmiany.

### Rag::Ask

Zwraca strukturę, z której kontroler buduje dzisiejszy JSON: wynik `Answer` oraz `search_result`
użyty do odpowiedzi (do `suggestions`). Przepisane pytanie trafia do logu, nie do odpowiedzi HTTP.

## Obsługa błędów

| sytuacja | zachowanie |
| --- | --- |
| Gemini wyłączone (brak klucza lub środowisko inne niż development) | fallback nieaktywny, wynik jak dziś. Wyszukiwarka musi działać bez Gemini |
| `QuestionRewriter` zgłasza błąd lub przekroczy timeout | wynik jak dziś (`no_results`), błąd w logu |
| Redis albo Ollama niedostępne | bez zmian: 503, obsługa w kontrolerze |
| `history` nie jest tablicą stringów | ignorowana (traktowana jak brak historii) |

## Testy

- `QuestionRewriter` na atrapie `FakeGemini`: przepisuje z historią, zwraca `nil` przy błędzie,
  `nil` przy pustej odpowiedzi, nie woła API przy wyłączonym Gemini.
- `Ask`: fallback odpala się **wyłącznie** przy braku wyników i niepustej historii; nie odpala się
  bez historii; nie odpala się, gdy pierwsze wyszukiwanie coś znalazło; po udanym przepisaniu do
  `Answer` idzie pytanie przepisane.
- Request spec `/api/ask`: żądanie z `history`, obcinanie limitów, zgodność wstecz bez `history`.
- Ewaluacja: `golden.yml` zyskuje opcjonalne pole `history`, a `rag:eval` liczy Recall@3 i MRR
  osobno dla pytań jednoturowych i dla rozmów. Bez tego skuteczność fallbacku jest niesprawdzona.

## Kryterium sukcesu

- Recall@3 i MRR na pytaniach jednoturowych bez regresji (dziś 0,98 / 0,90).
- Rozmowy wielotury w `golden.yml` trafiają w oczekiwane pliki — liczba do ustalenia pierwszym
  pomiarem, bo dziś nie ma punktu odniesienia.
- Typowa tura nie zwalnia: fallback nie wykonuje żadnego wywołania, gdy pierwsze wyszukiwanie
  zwróciło wyniki.
