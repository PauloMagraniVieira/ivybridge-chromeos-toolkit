# Ivy Bridge ChromeOS & ARCVM Deep-Dive Toolkit

> **Reverse-Engineering, GPU Injection & Architectural Limitations of Modern ChromeOS (R150 LTS) on Legacy Intel Ivy Bridge (2012) Hardware**

[![Hardware](https://img.shields.io/badge/Hardware-Intel%20Core%20i5--3230M%20%7C%20HD%204000-blue)](#)
[![System](https://img.shields.io/badge/ChromeOS-R150%20LTS%20%28rammus%29-green)](#)
[![Framework](https://img.shields.io/badge/Brunch-R150-orange)](#)
[![License](https://img.shields.io/badge/License-MIT-purple)](#)

---

## 📌 Visão Geral do Projeto

Este repositório documenta uma investigação aprofundada de engenharia reversa sobre a viabilidade de executar o **ChromeOS moderno (R150 LTS)** e o subsistema **ARCVM (Android 13 / Tiramisu)** em processadores de **3ª Geração Intel (Ivy Bridge / 2012)** com gráficos integrados **Intel HD 4000**.

O hardware de testes utilizado foi um **Dell Inspiron 7520 Special Edition** (Intel Core i5-3230M, 6 GB DDR3, Kingston 120GB SSD).

---

## 🏆 As Vitórias Técnicas (O que funciona 100%)

1. **Aceleração Gráfica Intel HD 4000 (Gen 7) no ChromeOS:**
   * A imagem `rammus` moderna removeu o suporte a Gen 7 (só inclui driver `iris` para Gen 8+).
   * Injetamos a pilha completa Mesa `crocus_dri.so` + GLVND extraída do ChromeOS Flex (`reven`).
   * **Resultado:** Interface do ChromeOS fluida a 60 fps, aceleração 3D, controle de brilho e decodificação de vídeo VA-API via `i965_drv_video.so`.
2. **Virtualização KVM sem AVX2 (`crosvm` / `crosh`):**
   * As compilações oficiais de Rust do ChromeOS falham com `SIGILL` (Invalid Opcode) em processadores sem `AVX2`/`BMI2`.
   * Realizamos o transplante dos binários Rust baseline x86-64 do Flex mantendo os domínios SELinux intactos.
   * **Resultado:** Terminal `crosh` funcional e motor de virtualização KVM ativo (suporte a Linux Crostini).
3. **Emulador de Instrução MOVBE no Kernel da VM:**
   * O `/init` do Android 13 (`libcrypto.so`) chama a instrução `MOVBE` (introduzida na 4ª geração Haswell).
   * Desenvolvemos e injetamos um emulador em Assembly/C bare-metal (`patch_arcvm_movbe_ivybridge.py`) dentro do entrypoint do kernel `vmlinux`, permitindo que o Android complete o boot (`sys.boot_completed=1`).

---

## 🛑 A Barreira Fatal: A Anatomia dos Erros 7 e 8 no ARCVM

Apesar de conseguirmos fazer o Android 13 completar o boot, a execução prática da **Google Play Store e apps Android é inviável** nesse silício devido a um limite físico de arquitetura:

* **O Erro 8 (`ARC_STOPPED`):**
  * Ocorre quando a VM ou o host morrem antes do handshake Mojo.
  * Causado por instruções não suportadas (`AVX2` no host `crosvm` ou `MOVBE` no guest `/init`).
* **O Erro 7 (`PROVISIONING_FAILED` / Timeout de Login):**
  * Ocorre quando o Android sobe, mas os apps sofrem crash contínuo em segundo plano.
  * **Causa-raiz:** O pipeline de UI do Android 13 (`libhwui.so` / `SkiaVK`) exige **Vulkan nativo**. O código oficial da Google (`VulkanManager.cpp`) executa:
    ```cpp
    LOG_ALWAYS_FATAL_IF(!gpuCount); // Aborta se vkEnumeratePhysicalDevices retornar 0
    ```
  * A GPU **Intel HD 4000 NÃO possui driver Vulkan físico** (o Mesa `anv` exige Gen 8+; o driver experimental `hasvk` é incompleto).
  * Como a thread de renderização sofre `SIGABRT` a cada tentativa de desenhar a janela de login, o ChromeOS expira o tempo limite e cospe o **Erro 7**.

---

## 🚀 Conclusão e Recomendação para a Comunidade

* **ChromeOS Desktop + PWAs:** **10/10 Excelente.** Liga em 6 segundos, navega a 800+ Mbps, roda YouTube, Netflix e WhatsApp Web com máxima fluidez e sem aquecimento.
* **ARCVM (Android 13) no Ivy Bridge:** **Inviável.** Não perca tempo tentando compilar Vulkan em software (Lavapipe), pois o consumo de CPU gerará throttling térmico e desempenho de 2 fps.

---

## 📁 Estrutura dos Scripts Disponíveis

* [`flash_chromeos_flex.sh`](flash_chromeos_flex.sh) — Utilitário de gravação USB do ChromeOS Flex no macOS.
* [`install_flex_dell_ssd.sh`](install_flex_dell_ssd.sh) — Script de particionamento e instalação direta no SSD interno.
* [`install_full_chromeos_brunch_dell.sh`](install_full_chromeos_brunch_dell.sh) — Instalador automatizado do Brunch Framework + `rammus` com patches.
* [`patch_arcvm_movbe_ivybridge.py`](patch_arcvm_movbe_ivybridge.py) — Injetor de emulação de `MOVBE` no kernel `vmlinux` x86-64 do Android.
* [`build_crosvm_skiagl_wrapper.py`](build_crosvm_skiagl_wrapper.py) — Wrapper freestanding ELF64 para interceptação de argumentos gráficos.

---

## ☕ Contribuição e Café

Se esta documentação economizou dias da sua vida ou ajudou a recuperar um notebook antigo:
* Deixe uma estrela ⭐️ neste repositório!
* Compartilhe com a comunidade do Brunch Framework e Reddit r/ChromeOS!
