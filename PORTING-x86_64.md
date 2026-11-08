# План работ: CactPkg x86_64 (CactOS 3.0.0)

Форк от `2.0.0` (i686). `MAJOR` → 3 по правилу «`MAJOR` = смена архитектурного
поколения»: пакетный менеджер перелинковывается под ABI ядра 3.0.0 и libc 3.0.0
(`CactKernel-x86_64`, `CactLibc-x86_64`, решения 5/9 ядра, решение 5 libc).

Файл-план, а не обещание. Инвентарь снят по коду; при расхождении верить коду.

## Что уже хорошо

Две PIE (`cactpkg` из `src/*.c` и пример `hello` из `examples/hello.c`) — чистый
C без ассемблера и прямых syscall, всё через `clibc.so`. Архитектурно-зависимы
только сборка и скрипт линковки.

Вендоренные заголовки (`pkg/cact-headers/payload/include/`) и `.cpkg`-артефакты
**не трекаются** (`.gitignore`: `repo/`, `pkg/*/payload/`): payload заголовков
пересобирается из `CactLibc-x86_64/include` отдельным таргетом, репозиторий —
`tools/cpkg.py`.

## Инвентарь 32-битных поверхностей

- `cross/i686-cact-clang.ini` — `-m32`, `cpu=i686`.
- `meson.build` — `_link_prefix` (`ld -m elf_i386 -pie`); заголовочный
  комментарий ссылается на i686-файл и `CactLibc-x86_32`.
- `link.ld` — `.rel.dyn`/`.rel.plt` (в x86_64 — `.rela.*`); нет `.data.rel.ro`.
  База `0x08000000` не двигается (решения 5/9 ядра).
- `meson_options.txt` — дефолты `../CactLibc-x86_32`, `../LocalRepoCactOS-x86_32/...`.
- `README.md` — бейджи/ссылки `i686`, `*-x86_32`.

## Решения

1. **Тулчейн как у соседей**: `cross/x86_64-cact-clang.ini` (`-m64`),
   `ld -m elf_x86_64`, дефолты → `../*-x86_64`.
2. **База `0x08000000` не двигается** (решение 5 libc).
3. **Скрипт линковки под ELF64**: `.rela.dyn`/`.rela.plt` и `.data.rel.ro`.
4. **Версии пакетов (`hello-2.0.0.cpkg` и пр.) не трогаем** — это метаданные
   payload'а, а не версия проекта; репозиторий всё равно пересобирается
   `tools/cpkg.py`.

## Этапы

Порт — один этап: меняются только тулчейн и скрипт линковки; коммит один.

### Фаза 0 — тулчейн и скрипт линковки

**Milestone:** `ninja -C build-meson` собирает `cactpkg` и `hello`;
`readelf -h` — `ELF64`/`EM_X86_64`.

## Проверки

- **Кросс-сборка** — `meson setup build-meson --cross-file
  cross/x86_64-cact-clang.ini -Dcactlib=../CactLibc-x86_64 && ninja -C
  build-meson`.
- **Заголовок/релокации** — `readelf -h`/`readelf -r build-meson/cactpkg`.
- **`repo`/`check`** — `tools/cpkg.py` на сборочной машине (python3), отдельная
  поверка не заводится.
- **На железе/в QEMU** — за ядром, `/usr/sbin/cactpkg`.

## Открытые вопросы

- **Payload заголовков** пересобирается из `CactLibc-x86_64/include` таргетом
  `cact-headers-payload` — правок не требует.
- **Образ — `ET_EXEC`** (как у прочих 2.0.0 PIE).
