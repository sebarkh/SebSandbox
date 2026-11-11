<p align="center"><img src="assets/icon.png" width="128" alt="SebSandbox"></p>

# SebSandbox

Uruchamianie niepewnych programów (`.exe`, `.msi`) w **Windows Sandbox** i raport o tym, co zmieniły w systemie.

*Run untrusted Windows programs in Windows Sandbox and get a report of what they changed (files, registry, scheduled tasks, processes, DNS queries and connection attempts). UI in Polish.*

## Funkcje

- **Prawy klik → „Uruchom w piaskownicy”** na pliku `.exe` / `.msi` albo okno główne z menu Start (wybór pliku, przeciąganie, lista ostatnich testów).
- **Opcje testu:** internet wł./wył., podłączenie folderu programu (dowolny folder nadrzędny, tylko do odczytu, bez kopiowania), raport automatyczny po zamknięciu programu i/lub co N minut.
- **Raport** z sekcją **PODEJRZANE** na początku:
  - pliki nowe / zmienione / usunięte (Program Files, ProgramData, profil użytkownika, Temp, System32, sterowniki, Autostart, `hosts`),
  - rejestr: autostart (Run/RunOnce), Winlogon, usługi, IFEO, wyjątki Defendera, wpisy odinstalowania,
  - zadania harmonogramu,
  - wszystkie procesy uruchomione w czasie testu (z linią poleceń, także te krótkotrwałe),
  - zapytania DNS i próby połączeń wychodzących - także w trybie bez internetu.
- Przycisk **„Kopiuj zawartość logu”** - cały raport do schowka (np. do wklejenia na forum albo do asystenta AI).
- GPU w piaskownicy włączone (gry działają), przycisk główny myszy jak na komputerze hosta.
- Opcjonalnie Process Monitor i Autoruns (Sysinternals) na pulpicie piaskownicy.

## Wymagania

- Windows 10/11 **Pro, Enterprise lub Education** (Windows Home nie ma Windows Sandbox).
- Wirtualizacja włączona w BIOS/UEFI (AMD: *SVM Mode*, Intel: *Intel Virtualization Technology*).
- Instalator sam włącza funkcję Windows Sandbox (potrzebny restart).

## Instalacja

Uruchom `SebSandbox-Setup.exe` (z Releases albo zbudowany samodzielnie). Instalator sprawdza wersję Windows, wirtualizację i funkcję Windows Sandbox, pozwala wybrać folder oraz opcje (menu kontekstowe, skróty, narzędzia Sysinternals) i dodaje wpis w *Zainstalowanych aplikacjach* z deinstalatorem.

Tryb cichy (np. w skryptach): `SebSandbox-Setup.exe -Silent [-Target <folder>]`.

## Budowanie

1. `build\version.txt` - numer wersji.
2. `build\Build.cmd`:
   - `Make-Installer.ps1` wstawia pliki z `src\` do szablonu instalatora,
   - [ps2exe](https://github.com/MScholtes/PS2EXE) kompiluje `SebSandbox-Setup.exe` z ikoną,
   - opcjonalnie podpis własnym certyfikatem.

## Struktura

```
src/                       program (instalowany do wybranego folderu)
  Start-SebSandbox.ps1     okno główne / okno opcji / okno raportu (host)
  Tools/Inside.ps1         działa w piaskownicy: monitorowanie, uruchomienie programu, raport
  Register.ps1             menu kontekstowe, skróty, wpis w Zainstalowanych aplikacjach
  Uninstall.ps1, Clean-Runs.ps1, SebSandbox.ico
build/                     szablon instalatora i skrypty budowania
```

## Ograniczenia

- Część złośliwego oprogramowania wykrywa maszynę wirtualną i nic w niej nie robi - brak zmian w raporcie nie dowodzi, że plik jest bezpieczny.
- Włączone GPU w piaskownicy to nieco większa powierzchnia ataku (sterownik grafiki hosta).
- Raport obejmuje wybrane obszary systemu, nie pełny obraz dysku i rejestru.

## Licencja

[MIT](LICENSE)
