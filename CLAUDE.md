# CarIPTV — правила репозитория

Видео с iPhone на экране машины через CarPlay, на стоянке. Первая фича — зеркалирование экрана iPhone на дисплей CarPlay; дальше IPTV-плеер (M3U/Xtream). **Swift/SwiftUI, только iOS** — не Flutter, в отличие от остального портфеля. Bundle id `weappico.cariptv`, команда Weappico Limited `JPN556JCX4`.

Домен `cariptv.com` (на 2026-10-15 свободен, не куплен). Прямой конкурент — CarTV (Lyntra, `com.lyntra.player`), разбор ниже.

**Канон портфеля — `~/app_database/`**, но он написан под Flutter: оттуда берутся правила работы (кто что решает, инварианты, куда что писать), не стек и не команды.

## Что нужно знать до первой правки

1. **Видео на экране машины показывается только с разрешения машины.** `CarState.videoAvailability` пускает картинку, когда CarPlay выдал своё окно, машина сообщает `supportsVideoPlayback == true` и `limitedUserInterfaces` пуст (CarPlay ограничивает интерфейс в движении). Исключение — только Simulator. Ослаблять проверку нельзя: это и правило Apple для категории CarPlay video, и безопасность водителя.
2. **Цепочка зеркалирования:** `ScreenRelay` (ReplayKit broadcast extension) → H.264 (`VideoEncoder`, VideoToolbox) → TCP на loopback `127.0.0.1:52741` (`RelayClient` / `MirrorProtocol`) → `MirrorReceiver` в приложении → `MirrorRenderer` → `AVSampleBufferDisplayLayer` в окне CarPlay (`CarMirrorViewController`). Код в `Shared/` компилируется в оба таргета.
3. **Звук не передаётся.** Приложение-источник само играет в динамики машины; картинка отстаёт на время кодирования и передачи. У CarTV на этом жалобы на рассинхрон — задержку держим минимальной (real-time, без B-кадров, лимит очереди 3 кадра).
4. **Приложение должно быть запущено**, иначе расширению некуда слать: оно завершает трансляцию с текстом «Open CarIPTV on the car screen».
5. **ReplayKit не работает в Simulator.** Для проверки цепочки там есть DEBUG-переключатель «Test pattern» (`TestPatternSource`): тот же кодер и тот же канал, превью на телефоне.

## Решения владельца

| Дата | Решение | Причина |
|---|---|---|
| 2026-10-14 | Нативный Swift, не Flutter | CarPlay, AVPlayer/AirPlay, ReplayKit, Live Activity — всё нативное; у Flutter нет видео-шаблонов CarPlay, кроссплатформенный выигрыш мал |
| 2026-10-15 | Название CarIPTV, слитно; в сторе бренд + «IPTV» отдельным словом | Так же просто, как CarTV; слово IPTV нужно для поиска |
| 2026-10-15 | Подпись — аккаунт Weappico (`JPN556JCX4`) | Решение владельца |
| 2026-10-15 | Первая фича — зеркалирование экрана на CarPlay | Решение владельца |

## Где что лежит

- `Config/` — Info.plist обоих таргетов и entitlements. Симуляторная сборка берёт `CarIPTV-Simulator.entitlements` (carplay-audio + carplay-video), сборка для устройства — `CarIPTV.entitlements`, пока пустой.
- `CarIPTV/CarPlay/` — сцена CarPlay, состояние машины, окно с видео.
- `CarIPTV/Mirror/` — приём потока и отрисовка.
- `CarIPTV/Debug/` — только DEBUG: тестовый сигнал и превью.
- Проект — `CarIPTV.xcodeproj` с синхронизируемыми папками (Xcode 16+): новый файл в папке попадает в таргет сам, `project.pbxproj` руками не правится.

## Проверки перед сдачей

```bash
xcodebuild -project CarIPTV.xcodeproj -scheme CarIPTV -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
xcodebuild -project CarIPTV.xcodeproj -scheme CarIPTV -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Обе без ошибок и предупреждений. В Simulator: I/O → External Displays → CarPlay, приложение видно на экране CarPlay. Изменение, видимое глазами, проверено там либо явно помечено непроверенным.

## Грабли этого репозитория

- **Xcode 26.3 (SDK iOS 26.2) не знает `CPSessionConfiguration.supportsVideoPlayback`** (появилось в iOS 26.4): читается через рантайм в `CarState.supportsVideoPlayback(_:)`. После обновления Xcode до 26.4+ заменить на свойство. Симуляторы iOS 26.3 и ниже видео в CarPlay не проверят. 2026-10-15.
- **`NWListener` с `requiredInterfaceType = .loopback` в Simulator сбрасывает каждое входящее соединение** («Connection reset by peer», до `newConnectionHandler` не доходит). Лечение — привязка к `127.0.0.1` через `requiredLocalEndpoint`, как в `MirrorReceiver`. 2026-10-15, Xcode 26.3, iOS 26.3.
- **Simulator iOS 26.3 подключает CarPlay-сцену без окна** (`window=false`, `supportsVideoPlayback=nil`): видео-путь там не проверить, статус и проверка доступа — проверяются. 2026-10-15.
- **Сборка на устройство с ключами CarPlay в entitlements не подпишется**, пока Apple не выдала их команде: профиль их не содержит. Ключи добавляются в `Config/CarIPTV.entitlements` после одобрения. 2026-10-15.

## Как это сделано у CarTV (разбор 1.1.2, 2026-10-14)

Entitlements: `carplay-audio`, `carplay-video`, `networking.multicast`, без навигации. Сцена CarPlay — `CPTemplateApplicationScene` с методом делегата, который получает `CPWindow`; в логах `supportsVideoPlayback` и «ownWindow». Видео — AVPlayer с AirPlay (`externalPlaybackActive`) плюс MobileVLCKit; зеркалирование — расширение ReplayKit `ScreenRelay`; свой DLNA-приёмник (SSDP + AVTransport); Live Activity; WKWebView-браузер; Adjust + Facebook SDK. Собран Xcode 26.6 / SDK 26.5, min iOS 18.

## Чего ещё нет

- **Entitlements CarPlay audio + video** — заявка владельца на developer.apple.com/contact/carplay. Без них на устройстве CarPlay-часть не запустится.
- Не проверено на устройстве и в машине: зеркалирование целиком, выдаёт ли CarPlay окно видео-приложению и перекрывает ли его шаблон-список.
- Иконка приложения, иконка CarPlay.
- IPTV-плеер (M3U, Xtream, EPG), DLNA-приёмник, AirPlay-путь для видео.
- Apphud / Adjust / Facebook — решение владельца, ещё не принято.
- Защита loopback-порта: сейчас к нему может подключиться любое приложение на телефоне.
