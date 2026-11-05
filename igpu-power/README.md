# b3l0w-igpu-power

Plugin de Noctalia `user/igpu-power`: menú para cambiar el perfil de la iGPU
(performance / balanced / low-power) y editar `modprobe.d`.

## Dependencia

`panel.luau` llama a `/usr/local/bin/igpu-power-menu.sh`. El script está en
este repo; para instalarlo:

```bash
sudo install -m755 igpu-power-menu.sh /usr/local/bin/igpu-power-menu.sh
```
