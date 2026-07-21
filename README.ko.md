# NoAjar - 로컬 코딩 에이전트를 위한 Mac 잠자기 제어

한국어 | [English](README.md)

<p align="center">
  <img src="Assets/noajar-icon.png" alt="NoAjar 아이콘" width="220">
</p>

NoAjar는 로컬 코딩 에이전트와 오래 실행되는 개발 작업이 Mac의 잠자기 때문에
중단되지 않도록 도와주는 작은 macOS 메뉴 막대 앱입니다.

Codex, Claude Code, OpenCode, OpenClaw, SSH 세션, 백그라운드 빌드와 테스트처럼
Mac이 잠들면 곤란한 작업을 위해 만들었습니다.

## 릴리스 채널

| 채널 | 다운로드 | 언제 사용하나 | 현재 범위 |
| --- | --- | --- | --- |
| Stable | [최신 안정판 다운로드](https://github.com/gityeop/NoAjar/releases/latest/download/NoAjar.zip) | 일반 사용자에게 권장하는 공개 빌드가 필요할 때 | Awake Mode, No Ajar Mode, App Auto Awake, duration, battery guard, 메뉴 UX, Universal 2 빌드, 일회성 베타 업데이트 확인 |
| Beta | [베타 다운로드](https://github.com/gityeop/NoAjar/releases/download/beta/NoAjar.zip) | 새 기능을 테스트하고 피드백을 줄 때 | Stable 기능 전체 + Keep Hotspot Connected + 반복 스케줄 |

이미 안정판을 사용 중이라면 `Settings` -> `Try Beta Updates`에서 베타 업데이트
feed를 한 번 확인할 수 있습니다. 이 기능은 안정판 업데이트 채널을 영구적으로
베타 채널로 바꾸지 않습니다.

## 설치

1. `NoAjar.zip`을 다운로드합니다.
2. 압축을 풉니다.
3. `NoAjar.app`을 `/Applications`로 옮깁니다.
4. NoAjar를 실행한 뒤 메뉴 막대 아이콘을 사용합니다.

No Ajar Mode를 처음 사용할 때는 닫힌 맥북의 잠자기 동작을 제어하기 위해 작은
helper를 설치하므로 관리자 권한이 한 번 필요합니다.

NoAjar는 macOS 13 이상이 필요합니다. 현재 안정판과 베타 빌드는 Apple Silicon과
Intel Mac을 모두 지원하는 Universal 2 앱입니다.

## 모드

NoAjar에는 두 가지 사용자 모드가 있습니다.

| 모드 | 동작 |
| --- | --- |
| Awake Mode | 맥북이 열린 상태에서 Mac과 디스플레이가 잠자기 상태로 들어가지 않게 합니다. 일반 macOS sleep assertion을 사용하며, 덮개를 닫았을 때의 동작은 바꾸지 않습니다. |
| No Ajar Mode | 맥북 덮개를 완전히 닫아도 Mac이 잠들지 않게 합니다. `pmset disablesleep 1`을 활성화하되, 기본적으로 디스플레이는 잠들 수 있게 둡니다. |

No Ajar Mode는 처음 한 번 helper를 설치한 뒤, 이후 세션을 시작할 때마다 관리자
프롬프트를 띄우지 않고 동작합니다.

## Stable 기능

안정판 메뉴는 현재 상태, 모드 선택, duration, 앱 자동화, 설정 중심으로 구성됩니다.

```text
Status

No Ajar Mode
Awake Mode
Duration

Apps
Settings

Quit
```

메뉴 막대 제목은 상태에 따라 바뀝니다.

- `💤`: 비활성 상태
- `☕`: Awake Mode 활성
- `🚀`: No Ajar Mode 활성

모드 항목은 토글입니다. 현재 활성화된 모드를 다시 클릭하면 세션이 종료됩니다.

### Duration

`Duration`은 다음에 수동으로 시작하는 모드에 적용됩니다. 모드가 실행 중일 때
duration을 바꾸면 현재 모드가 선택한 duration으로 다시 시작됩니다.

Duration 옵션:

- Until Stopped
- 30 Minutes
- 1 Hour
- 4 Hours
- 8 Hours
- Stop Below: Keep Running, 20%, 30%, 40%, 50%

### Apps

`Apps`에는 다음 항목이 있습니다.

- App Auto Awake: 설정한 앱 또는 프로세스 이름이 실행 중일 때 자동으로 시작합니다.
- Add Apps: `.app` 번들을 직접 선택합니다.
- Clear Apps: 감시 중인 앱 목록을 지웁니다.
- Mode: App Auto Awake에서 사용할 Awake Mode 또는 No Ajar Mode를 선택합니다.
- Apps: 현재 감시 중인 앱 이름을 보여줍니다.

### Settings

`Settings`에는 다음 항목이 있습니다.

- Hotkey: NoAjar 메뉴를 엽니다. 기본값은 `Cmd-Opt-L`입니다.
- Hotkey -> Enabled: 전역 핫키를 켜거나 끕니다.
- Hotkey -> Set Hotkey: 키를 직접 눌러 새 단축키를 기록합니다.
- Launch at Login.
- Check for Updates.
- Automatically Check for Updates.
- Automatically Install Updates.
- Try Beta Updates: 베타 feed를 한 번 확인합니다.
- Version: 설치된 앱 버전과 빌드를 표시합니다.

현재 핫키는 메뉴를 여는 용도입니다. `Cmd-1`, `Cmd-2`, 숫자키로 메뉴 항목을
선택하는 기능은 현재 구현되어 있지 않습니다.

## Beta 기능

베타 채널에는 현재 Keep Hotspot Connected와 반복 스케줄 기능이 추가되어
있습니다. 이 기능들은 아직 테스트 중이며, 특히 Mac 모델별 동작과 iPhone 핫스팟
상태에 따라 피드백이 필요합니다.

### Keep Hotspot Connected

베타 메뉴에서는 `Keep Hotspot Connected`가 `Schedule`과 `Apps` 사이에 표시됩니다.

하위 메뉴에는 다음 항목이 있습니다.

- Keep Hotspot Connected: 기능을 켜거나 끕니다.
- Hotspot: 저장된 대상 핫스팟 이름을 보여줍니다.
- Use Current Wi-Fi as Hotspot: 현재 연결된 Wi-Fi 이름을 대상 핫스팟으로 저장하고 기능을 켭니다.
- Forget Hotspot: 저장된 대상 핫스팟을 지웁니다.

No Ajar Mode가 활성화된 동안 NoAjar는 저장된 핫스팟을 계속 확인하고, Wi-Fi가
끊기거나 다른 네트워크로 바뀌면 macOS에 재연결을 요청할 수 있습니다. 저장된
핫스팟이 Instant Hotspot으로만 보이는 경우에는 Wi-Fi 연결 전에 실험적인 macOS
private API fallback을 사용합니다.

이 기능은 iPhone 핫스팟 끊김을 줄이는 데 도움이 될 수 있지만, iOS가 숨기거나
사용할 수 없게 만든 핫스팟을 강제로 나타나게 하지는 못합니다.

저장된 핫스팟이 있을 때 No Ajar Mode를 수동으로 시작하면 NoAjar가 해당 핫스팟을
유지할지 묻습니다. 스케줄로 시작된 No Ajar 세션은 질문창을 띄우지 않고, 각
스케줄의 Network 설정을 사용합니다.

### Schedule

베타 메뉴에서는 `Schedule`이 `Duration` 아래에 표시됩니다.

메뉴 제목은 다음 중 하나로 표시됩니다.

- `Schedule: Off`
- `Schedule: 1 Rule`
- `Schedule: N Rules`
- `Schedule: Active`

`Schedule`에는 다음 항목이 있습니다.

- Scheduled Mode: 전체 스케줄 규칙을 켜거나 끕니다.
- Edit Schedules...
- 현재 활성 스케줄 또는 다음 스케줄 요약

규칙이 없어도 Scheduled Mode를 켤 수 있습니다. Scheduled Mode를 끄면 Schedule만
원인인 세션은 즉시 종료되고, 사용자가 직접 시작한 세션과 별도의 실행 조건이 남아
있는 App Auto Awake 세션은 계속 실행됩니다.

스케줄 편집 창은 다음 기능을 지원합니다.

- 전체 Scheduled Mode 체크박스
- 여러 개의 enabled/disabled 규칙
- 규칙별 Awake Mode 또는 No Ajar Mode
- 요일 선택
- 시작/종료 시간
- 규칙별 저장된 Wi-Fi 또는 핫스팟 Network 선택 콤보박스
- 규칙 삭제
- Add Rule, Cancel, Save

같은 요일에서 규칙 시간이 겹치면 저장할 수 없습니다. `09:00-12:00`,
`12:00-18:00`처럼 바로 이어지는 규칙은 허용됩니다. 종료 시간이 시작 시간보다
빠르거나 같으면 overnight schedule로 처리됩니다.

스케줄은 NoAjar 앱이 실행 중일 때만 동작합니다. 재부팅 또는 로그인 후에도
스케줄을 쓰려면 `Settings` -> `Launch at Login`을 켜두세요.

스케줄로 시작된 세션을 사용자가 직접 끄거나 다른 모드로 바꾸면, 현재 스케줄
창이 끝날 때까지 같은 규칙을 다시 시작하지 않습니다. 다음 스케줄 창은 정상적으로
동작합니다.

## CLI

앱 번들에는 `noajar` CLI가 포함되어 있습니다.

다운로드한 앱에서 바로 실행할 수 있습니다.

```sh
/Applications/NoAjar.app/Contents/Helpers/noajar status
```

터미널 어디서든 `noajar`로 실행하려면 한 번만 심볼릭 링크를 만듭니다.

```sh
sudo ln -sf /Applications/NoAjar.app/Contents/Helpers/noajar /usr/local/bin/noajar
```

No Ajar Mode를 8시간 동안 실행:

```sh
noajar start --no-ajar --duration 8h
```

Awake Mode를 1시간 동안 실행:

```sh
noajar start --awake --duration 1h
```

배터리 사용을 허용하되 40%에서 중지:

```sh
noajar start --no-ajar --allow-battery --min-battery 40
```

디스플레이도 깨어 있게 유지:

```sh
noajar start --duration 1h --display-awake
```

베타 CLI 핫스팟 명령:

```sh
noajar start --no-ajar --hotspot-keepalive
noajar start --no-ajar --hotspot-ssid "My iPhone"
noajar hotspot-keepalive --hotspot-ssid "My iPhone" --force-reconnect
```

상태 확인:

```sh
noajar status
```

정상 잠자기 동작 복원:

```sh
noajar stop
```

## 소스에서 빌드

전체 빌드:

```sh
make build
```

앱 번들 빌드:

```sh
make app
```

앱 번들은 다음 경로에 생성됩니다.

```text
build/NoAjar.app
```

실행:

```sh
open build/NoAjar.app
```

helper 제거:

```sh
make uninstall-helper
```

## 안전

닫힌 맥북을 가방이나 밀폐된 공간 안에서 실행한 채로 오래 두지 마세요.
No Ajar Mode는 발열과 배터리 소모를 만들 수 있습니다. 가능하면 전원을 연결하고,
안정적인 표면 위에서 제한된 시간 동안 사용하세요.
