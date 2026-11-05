# b3l0w-igpu-power

Plugin de Noctalia `user/igpu-power`: menú para cambiar el perfil de la iGPU
(performance / balanced / low-power) y editar `modprobe.d`.

## Backend

El script `igpu-power-menu.sh` vive en **`b3l0w-cli/internal/plugins/scripts/`**.
Para instalarlo:

```bash
b3l0w plugins scripts
```

Eso lo copia a `/usr/local/bin/igpu-power-menu.sh`, que es la ruta que usa
`panel.luau`.
