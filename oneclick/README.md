# UZ801 一鍵備份 / 刷 OpenWRT / 還原（Windows）

適用 UZ801 v3.2（MSM8916）。OpenWRT 映像來自 [AlienWolfX/HandsomeMod-UZ801 v1.0-alpha](https://github.com/AlienWolfX/HandsomeMod-UZ801/releases/tag/v1.0-alpha)，腳本預設從 [pCloud 鏡像](https://filedn.com/l80M1m5GL7NXLyhbNmnccOu/UZ801-USB-MODEM/openwrt/) 下載並檢查 SHA256（`d3d933f2…6e32`）。本 repo 不放任何韌體或備份檔。

## 需要
- Windows 10 以上、Python 3、Git、Android platform-tools（adb / fastboot）放在 PATH
- EDL（9008）若用 Qualcomm QDLoader 驅動（COM 埠），edl 可能在 Sahara hello 卡住；此時用 [Zadig](https://zadig.akeo.ie/) 把 9008 裝置換成 WinUSB，卡住後需拔插網卡
- 原廠韌體要先開 ADB：瀏覽 `http://192.168.100.1/usbdebug.html`

## 步驟（雙擊即可）
| 檔案 | 作用 | 會寫入網卡？ |
| --- | --- | --- |
| `0-setup.bat` | 檢查工具，下載 bkerler/edl 到 `tools\edl` | 否 |
| `1-backup.bat` | 進 EDL，整顆 dump + 逐分區 dump 到 `backups\<時間>\`，寫 SHA256SUMS | 否 |
| `2-flash-openwrt.bat` | 驗證備份後下載 / 解開 OpenWRT release，用 fastboot 逐步刷入；**先用這台網卡自己的 modemst1/2、fsg、fsc 蓋掉 release 內附（別台的）檔案**，輸入 YES 才刷 | **是** |
| `restore-modem-only.bat` | 只寫回 modemst1/2、fsg、fsc（IMEI、訊號救援） | **是** |
| `restore-stock-full.bat` | 把整顆 `full_backup.bin` 寫回，回到備份當下狀態 | **是** |

進階參數（PowerShell）：
```powershell
.\uz801.ps1 flash -ImagePath D:\OpenWRT-UZ801_2026.tar.xz -ImageSha256 <hash>
.\uz801.ps1 restore-modem -BackupDir .\backups\20261118-120000
```

## 注意
- `backups\` 已被 `.gitignore` 排除。裡面有這台網卡專屬的 IMEI 與校準資料，**不要 commit、不要分享**，請另外存一份到別的地方。
- modem 分區只能寫回同一台網卡的備份。修改 IMEI 在許多地區違法。
- 刷入後若沒訊號，先試 `restore-modem-only.bat`，再參考 wiki 的 Troubleshooting（Changing Modem Region）。
- 刷 OpenWRT 只用 fastboot；但 OpenWRT 會換掉分區表（modem、persist、system 等都會消失），之後回原廠或 `restore-*` 都需要 EDL（Zadig 換驅動）＋ `restore-stock-full.bat`。

## 實測紀錄（2026-11-18，Windows 11，UZ801 原廠 V2.3.11）
- **EDL 在 Qualcomm QDLoader（COM 埠）驅動下完全沒有回應**，edl 收到 0 bytes，卡住後要拔插網卡。改用 Zadig 換成 WinUSB 才能用 `1-backup.bat` / `restore-*`。
  - 替代做法：原廠韌體的 adb 本身是 root，可以用 `adb exec-out dd if=/dev/block/mmcblk0pNN` 唯讀備份每個分區和整顆 `mmcblk0`。
- 刷機只用 fastboot，`2-flash-openwrt.bat` 不需要 EDL。release 內附的 modemst1/2、fsg 來自別台，腳本會先換成這台網卡的備份。
- 刷完之後，Windows 會把網卡綁在舊的原廠 adb 驅動上（「Android ADB Recovery Interface」）：
  1. 用系統管理員權限移除該裝置和舊的 adb 驅動（`pnputil /remove-device`、`pnputil /delete-driver oemNN.inf /uninstall`），再拔插網卡，就會變成「USB 複合裝置」。
  2. RNDIS 介面會出現錯誤代碼 28：在裝置管理員選「網路介面卡 → Microsoft → 遠端 NDIS 相容裝置」。
  3. 沒插 SIM 時，Windows 可能把網卡當成預設上網路徑，導致電腦斷網。把該介面卡的介面計量（metric）設高一點即可，例如 `Set-NetIPInterface -InterfaceAlias "乙太網路 N" -InterfaceMetric 500`。
- OpenWRT 預設 **Wi‑Fi 沒有密碼、root 沒有密碼**，刷完請立刻設定（LuCI → System → Administration；Network → Wireless 改成 WPA2-PSK）。
- 預期燈號：紅燈閃，偶爾亮藍燈。LuCI 在 http://192.168.1.1。
