# abuild на apk v3

Переработанный `abuild` (3.18.0_rc7-r1), который целиком работает с **apk v3**:

* пакеты создаются через `apk mkpkg` (ADB-контейнер, подпись, zstd);
* индекс репозитория — `apk mkndx` → `Packages.adb` вместо `APKINDEX.tar.gz`;
* сжатие всего конвейера — zstd (пакеты, индекс, man-страницы), с откатом на
  deflate/gzip, если в apk или системе zstd нет;
* старый конвейер v2 (`control.tar.gz` + `data.tar.gz` + `abuild-tar --hash` +
  подпись `abuild-sign` с `.SIGN.*`) убран.

## Структура каталогов

```
bin/apk            обёртка: локальный apk с LD_LIBRARY_PATH
tools/             собранный apk-tools 3.0.8 с -Dzstd=enabled (bin/, lib/)
apksrc/            исходники apk-tools 3.0.8 (meson build в apksrc/build)
dl/, deps/         dev-пакеты (zstd-dev, openssl-dev, linux-headers, meson)
                   и извлечённые из них заголовки/`.pc` для локальной сборки
src/abuild         основной скрипт (v3-конвейер)
src/abuild-sign    подписчик: apk adbsign для v3, legacy-путь для v2-индексов
share/default.conf конфигурация (секция «apk v3»)
share/functions.sh общий код (не менялся)
tests/             дымовые тестовые пакеты (hello, shim)
repo/              выходной REPODEST из последнего прогона тестов
```

## Локальный apk с zstd

Системный apk на этой машине собран Alpine'ом с `-Dzstd=disabled`, поэтому
abuild ищет apk в таком порядке:

1. `$APK` из окружения/конфига, если задан;
2. `<корень дерева>/bin/apk` (обёртка над `tools/bin/apk`);
3. `apk` из `$PATH`.

Абсолютный путь разрешается **до** загрузки `functions.sh`, потому что
`readconfig()` уже вызывает `$APK --print-arch`.

Пересборка apk:

```sh
# заголовки/`.pc` извлекаются из пакетов в dl/, префикс в *.pc правится на deps/usr
export PKG_CONFIG_PATH="$PWD/deps/usr/lib/pkgconfig:$PWD/deps/usr/share/pkgconfig"
export CFLAGS="-I$PWD/deps/usr/include" LDFLAGS="-L$PWD/deps/usr/lib"

cd apksrc
meson setup build \
    -Dprefix="$PWD/../tools" -Dzstd=enabled \
    -Ddocs=disabled -Dhelp=disabled -Dlua=disabled -Dpython=disabled -Dtests=disabled
ninja -C build && ninja -C build install
```

Проверка, что zstd включён: `od -A n -N 8 -t x1 <файл>` — после магии `41 44 42 63`
должно идти `28 b5 2f fd` (рамка zstd).

## Сборка пакета

```sh
cd tests/hello
/tmp/wip/ab/src/abuild -P /path/to/REPODEST        # как обычно
/tmp/wip/ab/src/abuild -f -P /path/to/REPODEST     # форс
```

`abuild` сам подхватывает `share/` и `bin/apk` из дерева, если запускать его
отсюда (`ABUILD_SHAREDIR`/`APK` можно переопределить явно).

Что происходит на границе с apk v3:

| внутри abuild (`.PKGINFO`) | в `apk mkpkg` |
|---|---|
| `pkgname/pkgver/arch` | `-I name/version/arch` (`arch` = `arch2dir`, noarch → `$CARCH`) |
| `pkgdesc/url/license/origin/maintainer/builddate` | `-I description/url/license/origin/maintainer/build-time` |
| `provider_priority`, `replaces_priority`, `install_if` | `-I provider-priority/replaces-priority/install-if` |
| `depend`, `provides`, `replaces` | одним аргументом `-I "key:a b c"` (повторный `-I` перезаписывает поле) |
| `triggers = путь` | `--trigger путь` |
| `commit` (только чистый чётный hex) | `-I repo-commit:...` (суффикс `-dirty` отбрасывается) |
| `.pre-install`, `.post-install`, `.pre-upgrade`, `.post-upgrade`, `.pre-deinstall`, `.post-deinstall`, `.trigger` | `-s тип:файл` |
| файлы из `$pkgdir` | `-F $pkgdir` (`--xattrs` включён) |

Индекс: `apk mkndx -c $APK_COMPRESSION --sign-key $PACKAGER_PRIVKEY --index <старый>
--output Packages.adb --description ... ./*.apk` — инкрементальный, пропавшие
пакеты из индекса удаляются.

## Подключение репозитория

В `Packages.adb` можно ссылаться двумя способами:

```sh
# 1) ключевое слово "v3" в списке репозиториев
echo 'v3 https://example.org/abuild' >> /etc/apk/repositories

# 2) прямая ссылка на файл индекса (base — его каталог, туда же идут *.apk)
apk add -X https://example.org/abuild/x86_64/Packages.adb hello
```

**Важно:** голый путь-каталог трактуется apk как v2-репозиторий
(`<dir>/<arch>/APKINDEX.tar.gz`), поэтому без ключевого слова `v3` ничего не
найдётся. То же касается `--repository-config`: apk v3 принимает **содержимое**
списка аргументом (`--repository-config 'v3 /path/to/repo'`), а не путь к файлу;
для файла есть `--repositories-file`.

Ключ подписи кладётся в `/etc/apk/keys/` (или указывается через `--keys-dir`);
пакеты и индекс подписаны одним ключом `PACKAGER_PRIVKEY`.

## Конфигурация (`share/default.conf`)

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `APK_COMPRESSION` | `zstd` | сжатие пакетов и индекса (`zstd`, `zstd:19`, `deflate`, `none`) |
| `APK_INDEX_FILE` | `Packages.adb` | имя индекса в репозитории |
| `DOC_COMPRESSION` | `zstd` | сжатие man-страниц в `-doc` (иначе gzip) |
| `APK` | см. выше | какой apk использовать |

Если выбранный `-c` apk не поддерживает, abuild один раз проситывает это на
пробном `mkpkg`, пишет warning и откатывается на `deflate`.

## Тесты

```sh
cd tests/hello && /tmp/wip/ab/src/abuild -f -P /tmp/wip/ab/repo
cd tests/shim  && /tmp/wip/ab/src/abuild -f -P /tmp/wip/ab/repo

# установка в одноразовый root
mkdir -p /tmp/root
bin/apk --root /tmp/root --usermode --initdb \
    --keys-dir "$HOME/.config/abuild" \
    --repository-config 'v3 /tmp/wip/ab/repo/tests' \
    add hello hello-doc shim
```

`hello` проверяет install-скрипты, триггер, `-doc` подпакет и man `.zst`;
`shim` даёт `provides /bin/sh` (и минимальный shell, чтобы хуки вообще могли
запуститься в пустом root).

## Ограничения и известные особенности

* **`-r` / `rootbld` используют системный apk** (`abuild-apk` → `/sbin/apk`),
  то есть apk без zstd: ставить *makedepends* они могут только из системных
  (v2) репозиториев, собранные здесь v3-репозитории для них недоступны.
  Полноценный `-r` на этой машине ещё и недоступен: `abuild-apk` не setuid,
  sudo нет, а `abuild -F` abuild запрещает.
* **Нет fakeroot → ownership файлов = build-user.** mkpkg записывает
  uid/gid как есть; abuild предупреждает об этом (`fakeroot disabled: ...`).
  С `fakeroot` (по умолчанию) ownership корректно переписывается в root.
* **`-dirty` теряется.** apk v3 принимает только чистый чётный hex
  `repo-commit`, поэтому суффикс `-dirty` от git отбрасывается.
* **`srcpkg` остался `.tar.gz`** — формат исходного пакета не трогали.
* **Legacy v2-индекс больше не генерируется.** `apk index` (v2) отказывается
  индексировать v3-пакеты (`file format not supported`), поэтому параллельный
  `APKINDEX.tar.gz` сделать нельзя. `abuild-sign` при этом по-прежнему умеет
  подписывать *старые* v2-индексы (gzip-магия → openssl + `.SIGN.*`), если
  нужно поддерживать существующие v2-репозитории.
* **`apk adbsign` возвращает 0 даже тогда, когда ничего не подписал**: он
  сначала проверяет старую подпись, при этом trust store сам не загружает, и
  без `--allow-untrusted` просто выходит. `abuild-sign` подписывает с
  `--allow-untrusted` и затем дополнительно проверяет результат
  (`adbdump` → строка `# sig ...: OK`), иначе падает.
* **Хуки пакета выполняются chroot'ом в целевой root** (apk v3 unshare +
  chroot), поэтому в одноразовом root должен быть `/bin/sh` — иначе
  `pre-install/post-install/trigger` завершаются с `execve: No such file`.
* **Старые клиенты apk-tools 2 v3-пакеты не ставят** — репозиторий полностью
  v3.
* man-страницы сжимаются `zstd -19`; если `zstd` в системе нет, abuild
  предупреждает и использует gzip.
