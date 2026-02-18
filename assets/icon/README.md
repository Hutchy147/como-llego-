Coloca estos archivos PNG en esta carpeta antes de generar iconos:

- `assets/icon/app_icon.png`
  - Uso: icono launcher base
  - Tamaño recomendado: `1024x1024` px
  - Fondo: puede ser sólido o transparente

- `assets/icon/app_icon_foreground.png`
  - Uso: capa foreground para icono adaptativo Android
  - Tamaño recomendado: `1024x1024` px
  - Fondo: transparente
  - Contenido centrado y con márgenes para evitar recortes por máscara adaptativa

Luego ejecuta:

```bash
flutter pub get
dart run flutter_launcher_icons
```
