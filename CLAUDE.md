# CarIPTV — правила репозитория

Видео с iPhone на экране машины через CarPlay, на стоянке: IPTV-плеер (M3U, Xtream с live, фильмами и сериалами), медиасерверы Jellyfin / Emby / Plex, зеркалирование экрана, приём трансляций из других приложений (DLNA), браузер, локальные видео. По функциям повторяет CarTV (Lyntra), оформление своё. **Swift/SwiftUI, только iOS** — не Flutter, в отличие от остального портфеля. Bundle id `weappico.cariptv`, команда Weappico Limited `JPN556JCX4`.

Домен `cariptv.com` (на 2026-10-15 свободен, не куплен).

**Канон портфеля — `~/app_database/`**, но он написан под Flutter: оттуда берутся правила работы (кто что решает, инварианты, куда что писать), не стек и не команды.

## Что нужно знать до первой правки

1. **Каналы и фильмы в машине показывает система, не мы** (официальный путь, iOS 26.4+). У строк списков CarPlay стоит `CPPlaybackConfiguration(preferredPresentation: .video)`; после выбора строки система сама показывает видео из нашего `AVPlayer` через AirPlay, а в машине без видео или в движении — «Сейчас играет». Своего окна для этого не нужно; `CPNowPlayingTemplate` вручную открывается только до iOS 26.4.
2. **Видео в машине — только с разрешения машины.** `CarState.videoAvailability`: машина сообщает `supportsVideoPlayback == true` и `limitedUserInterfaces` пуст (CarPlay ограничивает интерфейс в движении). Ослаблять проверку нельзя: это правило Apple для категории CarPlay video и безопасность водителя.
3. **Один плеер на всё приложение** — `PlaybackController` (AVPlayer, AirPlay-видео включено: через него система и показывает видео в машине). Держит очередь — список, из которого запущен канал; «следующий/предыдущий» на экране, экране блокировки и кнопках руля идут по ней. Каналы, локальные видео и трансляции из других приложений играют через него.
4. **Зеркалирование рисуется в собственное окно CarPlay** (`CarScreenViewController`), и только если CarPlay его выдал: `CarState.mirroringAvailable` = окно есть + видео разрешено. Apple документирует это окно только для навигаторов, официального пути зеркалирования для video-приложений нет — на устройстве может не заработать. Цепочка: `ScreenRelay` (ReplayKit) → H.264 (`VideoEncoder`) → TCP `127.0.0.1:52741` (`RelayClient` / `MirrorProtocol`) → `MirrorReceiver` → `MirrorRenderer` → окно CarPlay. Код в `Shared/` компилируется в оба таргета. Звук не передаётся: источник сам играет в динамики машины.
5. **DLNA-приёмник** (`Cast/`) — UPnP MediaRenderer: SSDP на 239.255.255.250:1900 (`SSDPResponder`), HTTP + SOAP (`HTTPServer`, `UPnP`, `CastReceiver`). Работает, пока подключён CarPlay или открыт экран Cast from an App. Нужен Wi-Fi.
6. **Токены серверов не попадают в сохранённые данные.** Избранное и недавнее хранят внутренние адреса `cariptv-item://…` и `cariptv-image://…` (`InternalURL`); `LibraryStore.resolvedURL` строит настоящий адрес с токеном из Keychain только в момент воспроизведения или показа картинки.
7. **Видео с Jellyfin, Emby и Plex идёт в HLS, который собирает сервер** (`master.m3u8`, `transcode/universal/start.m3u8`): так играют MKV и кодеки, которых AVPlayer напрямую не берёт.
8. **Приложение не содержит контента.** Источники добавляет пользователь; тексты в пустых состояниях и в форме источника это говорят — для App Review не убирать.

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
| 2026-10-16 | Apple выдала **CarPlay Video** (case 22905383). В entitlements только `carplay-video`; capability включена на App ID, подпись на устройство проходит | Apple: Audio и Video в одном приложении не поддерживаются. Video-приложение скрыто в машинах без поддержки видео; Audio-разрешение Apple расширила на смешанный звук+видео — выбор между ними за владельцем |

## Где что лежит

- `Config/` — Info.plist обоих таргетов и entitlements. И устройство, и Simulator — только `com.apple.developer.carplay-video`, как выдано.
- `CarIPTV/Library/` — источники, разбор M3U, клиенты Xtream (`XtreamClient` + `XtreamCatalog` для фильмов и сериалов), Jellyfin/Emby (`JellyfinClient`), Plex (`PlexClient`), общий протокол `MediaServer`, Keychain, `LibraryStore` (JSON в Application Support, пароли и токены — в Keychain).
- `CarIPTV/Playback/` — `PlaybackController`.
- `CarIPTV/Cast/` — DLNA-приёмник.
- `CarIPTV/CarPlay/` — сцена CarPlay (вкладки Favorites / Recent / Screen, у строк — `playbackConfiguration`), состояние машины (`CarState`), окно для зеркалирования.
- `CarIPTV/Mirror/` — приём зеркалирования и отрисовка.
- `CarIPTV/Phone/` — экраны телефона по вкладкам.
- `CarIPTV/Debug/` — только DEBUG: тестовый сигнал, превью зеркалирования, `DebugSources` (аргумент запуска `-CarIPTVDebugSources http://127.0.0.1:8766` добавляет Xtream и Jellyfin с этого адреса, логин `1`, пароль `2`, и M3U `/playlist.m3u` с программой XMLTV). Аргумент `-CarIPTVDebugLandscape YES` поворачивает Simulator при открытии плеера (`OrientationLock`).
- `CarIPTV/App/AppDelegate.swift` — `OrientationLock`: телефон в портрете, плеер разрешает альбомную ориентацию; окно CarPlay не ограничивается.
- `CarIPTV/Library/ProgramGuide.swift` — «сейчас / далее»: Xtream (`get_short_epg`, кеш 10 минут) и XMLTV для M3U (файл читается раз на источник, кеш на диске 12 часов). Откуда брать программу канала, решает `LibraryStore.guideLookup(for:)`.
- `CarIPTV/Library/XMLTV.swift` — программа XMLTV: ссылка из заголовка плейлиста (`url-tvg`, `x-tvg-url`) или из формы; `.xml.gz` распаковывается потоком, XML читается потоком, в памяти — только каналы источника на ближайшие 36 часов. Канал находится по `tvg-id`, без него — по названию (без пробелов, знаков и суффиксов HD/FHD/UHD/SD/4K).
- `CarIPTV/Phone/Home/VoiceSearch.swift` — голосовой поиск (Speech, на устройстве, если поддерживается).
- `CarIPTVTests/` — Swift Testing: M3U, Xtream, Jellyfin/Emby, Plex, внутренние адреса, адресная строка браузера, протокол зеркалирования, UPnP/SOAP/SSDP, HTTP-разбор. Клиенты серверов проверяются целиком через `StubURLProtocol` (подмена ответов по хосту).
- Проект — `CarIPTV.xcodeproj` с синхронизируемыми папками (Xcode 16+): новый файл в папке попадает в таргет сам.

## Проверки перед сдачей

```bash
xcodebuild test -project CarIPTV.xcodeproj -scheme CarIPTV -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/DerivedData
xcodebuild -project CarIPTV.xcodeproj -scheme CarIPTV -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```

Xcode 27.1, SDK iOS 27.1; симулятор iPhone 18 Pro на iOS 27.0. Тесты зелёные, сборки без ошибок и предупреждений (строки `appintentsmetadataprocessor … warning` — служебные, не наши). Вторая команда подписывает сборку на устройство: в `embedded.mobileprovision` должен быть `com.apple.developer.carplay-video`. Изменение, видимое глазами, проверено в симуляторе либо явно помечено непроверенным.

Серверы проверяются на локальной имитации (Python): она отвечает как панель Xtream и как Jellyfin, отдаёт M3U-плейлист с программой XMLTV (`.xml.gz`, время в +0300), постеры и настоящий HLS (fMP4, сгенерирован AVAssetWriter). Приложение запускается с `-CarIPTVDebugSources`, дальше — обычная навигация.

DLNA проверяется с Mac без телефона: Simulator живёт в сети Mac, Python-скрипт шлёт M-SEARCH на 239.255.255.250:1900, находит `CarIPTV` и управляет через SOAP (SetAVTransportURI → Play → GetTransportInfo).

## Грабли этого репозитория

- **В Xcode 27 нет Simulator.app, а в его замене DeviceHub нет экрана CarPlay** (`Xcode.app/Contents/Applications/DeviceHub.app`, `com.apple.dt.Devices`). Просмотрены меню Device / Controls / View / Window, «More» (…) и «+» на панели, инспекторы Settings и Info, `simctl io` — внешних экранов нигде нет. Экран машины проверяется только с настоящим iPhone: CarPlay Simulator из Additional Tools for Xcode (iPhone по кабелю) или машина. 2026-10-16.
- **Simulator iOS 26.3 подключал CarPlay-сцену без окна** (`window=false`, `supportsVideoPlayback=nil`), а video-приложение в его CarPlay не видно вовсе. 2026-10-15.
- **`NWListener` с `requiredInterfaceType = .loopback` в Simulator сбрасывает каждое входящее соединение.** Лечение — привязка к `127.0.0.1` через `requiredLocalEndpoint`, как в `MirrorReceiver`. 2026-10-15.
- **AVKit `VideoPlayer` ставит воспроизведение на паузу, когда экран плеера закрывают.** `PlayerView` возобновляет его в `onDisappear`, если играло. Не убирать — иначе машина остаётся с паузой. 2026-10-15.
- **AVPlayer не играет MP4 с сервера без Range-запросов** (например, `python -m http.server`). Для локальных тестов нужен сервер с `206 Partial Content`. 2026-10-15.
- **Ввод латиницы в Simulator через инструмент управления приходит в русской раскладке** («реезЖ//» вместо «http://»), переключатель «Use the Same Keyboard Language as macOS» не помогает. Буфер обмена Simulator синхронизируется с Mac и его перезаписывают другие программы. Для тестовых источников — `-CarIPTVDebugSources`. 2026-10-15.
- **Simulator: поворот через меню Device недоступен**, пока Simulator не на переднем плане; для проверки альбомного плеера — `-CarIPTVDebugLandscape YES`. `requestGeometryUpdate` сразу после снятия блокировки ориентации отказывает («Supported: portrait») — система применяет новые ориентации с задержкой. 2026-10-16.
- **Микрофон в Simulator — настоящий микрофон Mac.** Голосовой поиск на нём не проверять без согласия владельца; проверено только отказ в разрешении. 2026-10-16.
- **`xcodebuild test` выключает симулятор после прогона**: перед ручной проверкой его нужно снова загрузить (`xcrun simctl boot`). 2026-10-15.
- **Клики в DeviceHub доходят, только когда его окно на текущем рабочем столе.** Если владелец в полноэкранном приложении, окно туда не перенести — проверку на экране отложить. Скриншоты — `xcrun simctl io <id> screenshot`, они работают всегда. 2026-10-16.
- **Мини-плеер выровнен по плавающей панели вкладок iOS 26+: 21 pt от краёв экрана** (`MiniPlayerBar.sideInset`; замерено на iPhone 18 Pro и 17e). До iOS 26 панель во всю ширину, отступ 12 pt. 2026-10-16.
- **Сборка на устройство с ключами CarPlay или multicast в entitlements не подпишется**, пока Apple не выдала их команде. 2026-10-15.

## Как это сделано у CarTV (разбор 1.1.2, 2026-10-14)

Entitlements: `carplay-audio`, `carplay-video`, `networking.multicast`, без навигации. Сцена CarPlay — `CPTemplateApplicationScene` с методом делегата, который получает `CPWindow`; в логах `supportsVideoPlayback` и «ownWindow». Видео — AVPlayer с AirPlay (`externalPlaybackActive`) плюс MobileVLCKit; зеркалирование — расширение ReplayKit `ScreenRelay`; свой DLNA-приёмник (SSDP + AVTransport); Live Activity; WKWebView-браузер; Adjust + Facebook SDK. Собран Xcode 26.6 / SDK 26.5, min iOS 18.

## Чего ещё нет

- **Entitlements:** **Multicast** (`com.apple.developer.networking.multicast`) не запрошен — без него DLNA на устройстве не найдут; заявка — владелец, developer.apple.com/contact/request/networking-multicast.
- **Не проверено:** весь экран CarPlay на iOS 27 — показ видео системой после выбора канала, вкладки Favorites / Recent / Screen, значки play/pause у строк (в DeviceHub экрана CarPlay нет — нужен iPhone); выдаёт ли CarPlay video-приложению своё окно, то есть работает ли зеркалирование в машине вообще; зеркалирование на устройстве; DLNA с настоящими приложениями (TikTok, Bilibili и т. п.); воспроизведение в фоне при выключенном экране телефона; **Jellyfin, Emby, Plex и Xtream VOD на настоящих серверах** — проверены только тестами и имитацией; Plex — вход кодом и выбор адреса сервера не проверялись вовсе.
- **Потоки M3U и Xtream:** только то, что играет AVPlayer (HLS, MP4). MPEG-TS напрямую, MKV в фильмах Xtream и часть кодеков — нет; нужен второй движок (VLCKit/MPVKit) — решение владельца, новая зависимость. Серверы Jellyfin/Emby/Plex это обходят своим HLS.
- **Xtream:** нет каталога архива; фильмы и сериалы загружаются заново при каждом открытии раздела.
- Live TV из Jellyfin/Emby/Plex, выбор языка, локализации, Live Activity.
- **Программа XMLTV:** правка ссылки на программу у уже добавленного источника (сейчас — только при добавлении); программа в CarPlay; на экране не проверялась — только тестами и `curl` к имитации.
- **Не проверено:** голосовой поиск на устройстве (в Simulator — только отказ в разрешении); кнопки руля «следующий/предыдущий» в машине.
- Pro / пейволл, Apphud / Adjust / Facebook — решение владельца.
- Политика конфиденциальности на `cariptv.com/privacy` (ссылка в настройках уже стоит), иконка приложения и CarPlay.
- Защита loopback-порта зеркалирования: к нему может подключиться любое приложение на телефоне.
