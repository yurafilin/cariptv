# CarIPTV — правила репозитория

Видео с iPhone на экране машины через CarPlay, на стоянке: IPTV-плеер (M3U, Xtream с live, фильмами и сериалами), медиасерверы Jellyfin / Emby / Plex, зеркалирование экрана, приём трансляций из других приложений (DLNA), браузер, локальные видео. По функциям повторяет CarTV (Lyntra), оформление своё. **Swift/SwiftUI, только iOS** — не Flutter, в отличие от остального портфеля. Bundle id `weappico.cariptv`, команда Weappico Limited `JPN556JCX4`.

Домен `cariptv.com` (на 2026-10-15 свободен, не куплен).

**Канон портфеля — `~/app_database/`**, но он написан под Flutter: оттуда берутся правила работы (кто что решает, инварианты, куда что писать), не стек и не команды.

## Что нужно знать до первой правки

1. **Видео на экране машины показывается только с разрешения машины.** `CarState.videoAvailability` пускает картинку, когда CarPlay выдал своё окно, машина сообщает `supportsVideoPlayback == true` и `limitedUserInterfaces` пуст (CarPlay ограничивает интерфейс в движении). Иначе плеер продолжает звуком. Исключение — только Simulator. Ослаблять проверку нельзя: это правило Apple для категории CarPlay video и безопасность водителя.
2. **Один плеер на всё приложение** — `PlaybackController` (AVPlayer). Каналы, локальные видео и трансляции из других приложений играют через него; телефон (`PlayerView`) и машина (`CarScreenViewController`) подключают к нему свои слои.
3. **Цепочка зеркалирования:** `ScreenRelay` (ReplayKit) → H.264 (`VideoEncoder`) → TCP `127.0.0.1:52741` (`RelayClient` / `MirrorProtocol`) → `MirrorReceiver` → `MirrorRenderer` → окно CarPlay. Код в `Shared/` компилируется в оба таргета. Звук не передаётся: источник сам играет в динамики машины.
4. **DLNA-приёмник** (`Cast/`) — UPnP MediaRenderer: SSDP на 239.255.255.250:1900 (`SSDPResponder`), HTTP + SOAP (`HTTPServer`, `UPnP`, `CastReceiver`). Работает, пока подключён CarPlay или открыт экран Cast from an App. Нужен Wi-Fi.
5. **Токены серверов не попадают в сохранённые данные.** Избранное и недавнее хранят внутренние адреса `cariptv-item://…` и `cariptv-image://…` (`InternalURL`); `LibraryStore.resolvedURL` строит настоящий адрес с токеном из Keychain только в момент воспроизведения или показа картинки.
6. **Видео с Jellyfin, Emby и Plex идёт в HLS, который собирает сервер** (`master.m3u8`, `transcode/universal/start.m3u8`): так играют MKV и кодеки, которых AVPlayer напрямую не берёт.
7. **Приложение не содержит контента.** Источники добавляет пользователь; тексты в пустых состояниях и в форме источника это говорят — для App Review не убирать.

## Решения владельца

| Дата | Решение | Причина |
|---|---|---|
| 2026-10-14 | Нативный Swift, не Flutter | CarPlay, AVPlayer/AirPlay, ReplayKit, Live Activity — всё нативное; у Flutter нет видео-шаблонов CarPlay |
| 2026-10-15 | Название CarIPTV, слитно; в сторе бренд + «IPTV» отдельным словом | Так же просто, как CarTV; слово IPTV нужно для поиска |
| 2026-10-15 | Подпись — аккаунт Weappico (`JPN556JCX4`) | Решение владельца |
| 2026-10-15 | Первая фича — зеркалирование экрана на CarPlay | Решение владельца |
| 2026-10-15 | Функции как у CarTV: вкладки Home / Favorites / Discover / Settings, браузер, Cast to Screen, Cast from an App, локальные видео | Владелец прислал скриншоты CarTV: «делай вот эти фичи» |
| 2026-10-15 | Тёмная тема; акцент оранжевый `#FF8A1A` — **временный**, цвет бренда не выбран | Машина и видео — тёмный интерфейс; акцент ждёт владельца |
| 2026-10-15 | Отложено: Pro/пейволл, выбор языка, голосовой поиск | Пейволл — после решения по Apphud; язык — когда будет вторая локализация |
| 2026-10-15 | Plex — вход кодом на plex.tv/link, без пароля в приложении | Пароль Plex не проходит через приложение; так же входят приложения на ТВ |

## Где что лежит

- `Config/` — Info.plist обоих таргетов и entitlements. Симуляторная сборка берёт `CarIPTV-Simulator.entitlements` (carplay-audio + carplay-video), сборка для устройства — `CarIPTV.entitlements`, пока пустой.
- `CarIPTV/Library/` — источники, разбор M3U, клиенты Xtream (`XtreamClient` + `XtreamCatalog` для фильмов и сериалов), Jellyfin/Emby (`JellyfinClient`), Plex (`PlexClient`), общий протокол `MediaServer`, Keychain, `LibraryStore` (JSON в Application Support, пароли и токены — в Keychain).
- `CarIPTV/Playback/` — `PlaybackController`, слой плеера.
- `CarIPTV/Cast/` — DLNA-приёмник.
- `CarIPTV/CarPlay/` — сцена CarPlay (вкладки Favorites / Recent / Screen), состояние машины, экран машины.
- `CarIPTV/Mirror/` — приём зеркалирования и отрисовка.
- `CarIPTV/Phone/` — экраны телефона по вкладкам.
- `CarIPTV/Debug/` — только DEBUG: тестовый сигнал, превью зеркалирования, `DebugSources` (аргумент запуска `-CarIPTVDebugSources http://127.0.0.1:8766` добавляет Xtream и Jellyfin с этого адреса, логин `1`, пароль `2`).
- `CarIPTVTests/` — Swift Testing: M3U, Xtream, Jellyfin/Emby, Plex, внутренние адреса, адресная строка браузера, протокол зеркалирования, UPnP/SOAP/SSDP, HTTP-разбор. Клиенты серверов проверяются целиком через `StubURLProtocol` (подмена ответов по хосту).
- Проект — `CarIPTV.xcodeproj` с синхронизируемыми папками (Xcode 16+): новый файл в папке попадает в таргет сам.

## Проверки перед сдачей

```bash
xcodebuild test -project CarIPTV.xcodeproj -scheme CarIPTV -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData
xcodebuild -project CarIPTV.xcodeproj -scheme CarIPTV -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Тесты зелёные, сборки без ошибок и предупреждений. Изменение, видимое глазами, проверено в Simulator (CarPlay: I/O → External Displays → CarPlay) либо явно помечено непроверенным.

Серверы проверяются на локальной имитации (Python): она отвечает как панель Xtream и как Jellyfin, отдаёт постеры и настоящий HLS (fMP4, сгенерирован AVAssetWriter). Приложение запускается с `-CarIPTVDebugSources`, дальше — обычная навигация.

DLNA проверяется с Mac без телефона: Simulator живёт в сети Mac, Python-скрипт шлёт M-SEARCH на 239.255.255.250:1900, находит `CarIPTV` и управляет через SOAP (SetAVTransportURI → Play → GetTransportInfo).

## Грабли этого репозитория

- **Xcode 26.3 (SDK iOS 26.2) не знает `CPSessionConfiguration.supportsVideoPlayback`** (появилось в iOS 26.4): читается через рантайм в `CarState.supportsVideoPlayback(_:)`. После обновления Xcode до 26.4+ заменить на свойство. 2026-10-15.
- **Simulator iOS 26.3 подключает CarPlay-сцену без окна** (`window=false`, `supportsVideoPlayback=nil`): видео на экране машины там не проверить. 2026-10-15.
- **`NWListener` с `requiredInterfaceType = .loopback` в Simulator сбрасывает каждое входящее соединение.** Лечение — привязка к `127.0.0.1` через `requiredLocalEndpoint`, как в `MirrorReceiver`. 2026-10-15.
- **AVKit `VideoPlayer` ставит воспроизведение на паузу, когда экран плеера закрывают.** `PlayerView` возобновляет его в `onDisappear`, если играло. Не убирать — иначе машина остаётся с паузой. 2026-10-15.
- **AVPlayer не играет MP4 с сервера без Range-запросов** (например, `python -m http.server`). Для локальных тестов нужен сервер с `206 Partial Content`. 2026-10-15.
- **Ввод латиницы в Simulator через инструмент управления приходит в русской раскладке** («реезЖ//» вместо «http://»), переключатель «Use the Same Keyboard Language as macOS» не помогает. Буфер обмена Simulator синхронизируется с Mac и его перезаписывают другие программы. Для тестовых источников — `-CarIPTVDebugSources`. 2026-10-15.
- **`xcodebuild test` выключает симулятор после прогона**: перед ручной проверкой его нужно снова загрузить (`xcrun simctl boot`). 2026-10-15.
- **Сборка на устройство с ключами CarPlay или multicast в entitlements не подпишется**, пока Apple не выдала их команде. 2026-10-15.

## Как это сделано у CarTV (разбор 1.1.2, 2026-10-14)

Entitlements: `carplay-audio`, `carplay-video`, `networking.multicast`, без навигации. Сцена CarPlay — `CPTemplateApplicationScene` с методом делегата, который получает `CPWindow`; в логах `supportsVideoPlayback` и «ownWindow». Видео — AVPlayer с AirPlay (`externalPlaybackActive`) плюс MobileVLCKit; зеркалирование — расширение ReplayKit `ScreenRelay`; свой DLNA-приёмник (SSDP + AVTransport); Live Activity; WKWebView-браузер; Adjust + Facebook SDK. Собран Xcode 26.6 / SDK 26.5, min iOS 18.

## Чего ещё нет

- **Entitlements от Apple:** CarPlay audio + video (заявка подана владельцем 2026-10-15), **multicast** (`com.apple.developer.networking.multicast`) — без него DLNA на устройстве не найдут. Заявка на multicast — владелец, developer.apple.com/contact/request/networking-multicast.
- **Не проверено:** зеркалирование на устройстве; CarPlay-вкладки (Favorites / Recent / Screen) на экране CarPlay; DLNA с настоящими приложениями (TikTok, Bilibili и т. п.); воспроизведение в фоне при выключенном экране телефона; **Jellyfin, Emby, Plex и Xtream VOD на настоящих серверах** — проверены только тестами и имитацией; Plex — вход кодом и выбор адреса сервера не проверялись вовсе.
- **Потоки M3U и Xtream:** только то, что играет AVPlayer (HLS, MP4). MPEG-TS напрямую, MKV в фильмах Xtream и часть кодеков — нет; нужен второй движок (VLCKit/MPVKit) — решение владельца, новая зависимость. Серверы Jellyfin/Emby/Plex это обходят своим HLS.
- **Xtream:** нет EPG и каталога архива; фильмы и сериалы загружаются заново при каждом открытии раздела.
- Live TV из Jellyfin/Emby/Plex, EPG для M3U, голосовой поиск, выбор языка, локализации.
- Pro / пейволл, Apphud / Adjust / Facebook — решение владельца.
- Политика конфиденциальности на `cariptv.com/privacy` (ссылка в настройках уже стоит), иконка приложения и CarPlay.
- Защита loopback-порта зеркалирования: к нему может подключиться любое приложение на телефоне.
