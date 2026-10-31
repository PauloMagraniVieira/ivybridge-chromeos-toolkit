# Guia Estratégico: Acer Aspire 3 A315-53-55DD (N17C4)

> **Lições Aprendidas no Dell (2012) & Protocolo Zero Desperdício de Tokens para o Acer Kaby Lake (7ª Geração)**

---

## 1. O Contraste Brutal: Dell Inspiron 7520 vs. Acer Aspire 3

O que era uma **barreira intransponível de silício no Dell** é **nativo e suportado no Acer**:

| Recurso Crítico | Dell Inspiron 7520 (Ivy Bridge / 2012) | Acer Aspire 3 A315-53 (Kaby Lake / 2017) | Impacto Prático no Acer |
| :--- | :--- | :--- | :--- |
| **Processador** | i5-3230M (3ª Geração) | **i5-7200U (7ª Geração)** | **2.5GHz a 3.1GHz, TDP de 15W** (não ferve como o Dell). |
| **Instruções de CPU** | `AVX1`, `SSE4.2` (Falta `AVX2`, `MOVBE`, `BMI`) | **`AVX2`, `FMA3`, `BMI1/2`, `MOVBE` NATIVOS** | **Zero patches de kernel!** Binários oficiais do ChromeOS e Android rodam sem `SIGILL`. |
| **Placa Gráfica** | Intel HD 4000 (Gen 7) | **Intel HD Graphics 620 (Gen 9.5)** | **Suporte Oficial da Google.** É a arquitetura padrão da imagem `rammus`! |
| **Suporte a Vulkan** | ❌ Não possui (OpenGL ES 3.0 máx.) | **✅ SIM, Vulkan 1.2 / 1.3 Oficial via Mesa `anv`** | **ARCVM / Play Store funcionam sem abortar o `SkiaVK`!** |
| **Armazenamento** | SATA III (Gargalo de cabo) | **Slot M.2 NVMe PCIe Gen3 x2** | Velocidades de **1.500+ MB/s** (3x mais rápido que o SATA). |
| **Gargalo Real do Acer** | Não é CPU/GPU | **Memória RAM (4 GB soldados)** | **O calcanhar de Aquiles do Acer é a RAM.** |

---

## 2. O Calcanhar de Aquiles do Acer: Como Não Jogar Dinheiro Fora na RAM

No histórico recuperado, registramos que um pente SODIMM comprado anteriormente **não deu boot**:
* **Por que isso aconteceu:** A controladora de memória integrada do i5-7200U com 4 GB soldados exige compatibilidade estrita de densidade e rank.
* **A regra de ouro:**
  1. Compre **8 GB DDR4-2400MHz ou 2666MHz SODIMM Single-Rank (1Rx8)** (marcas recomendadas: Crucial / Kingston ValueRAM).
  2. Total com upgrade: **12 GB em Dual-Channel assimétrico (Flex Mode)**.
  3. **Com 12 GB de RAM e NVMe:** O Acer vira um monstro para desenvolvimento, Docker, VS Code e ChromeOS. Com apenas os 4 GB soldados, o ARCVM (Android) vai sofrer com o `lmkd` (Low Memory Killer) matando abas em segundo plano.

---

## 3. Protocolo "Zero Tokens": Como Instalar o ChromeOS no Acer sem Sofrimento

No Acer, você **NÃO precisa reinventar a roda nem rodar 200 comandos de depuração**:

1. **Imagem de Recuperação Correta:**
   * Use o **Brunch Framework R150** com a imagem de recuperação oficial **`rammus`** (feita sob medida para processadores Kaby Lake / Intel HD 620).
2. **Zero Patches de GPU:**
   * A Intel HD 620 usa o driver padrão `iris` e o driver Vulkan `anv` que **já vêm de fábrica dentro da imagem da Google**. Não injete Mesa do Flex nem emulador de MOVBE!
3. **Se quiser apenas trabalho rápido de desenvolvimento (sem Play Store):**
   * Instale o **ChromeOS Flex oficial** (imagem `reven`). Ele reconhece todo o hardware do Acer no primeiro segundo, com boot em 4 segundos e zero manutenção.
4. **Se quiser Play Store + Linux Crostini (com o pente de 8 GB instalado):**
   * Instale o Brunch + `rammus`. O Android 13 sobe nativo via Vulkan sem nenhum erro de RenderThread.

---

## 4. Onde Encontrar Este Histórico no Futuro

Toda a transcrição detalhada da sessão que gerou essas lições de engenharia foi salva em:
`TRANSCRIPT_HISTORICO_ENGENHARIA.md` no repositório GitHub:
👉 **[https://github.com/PauloMagraniVieira/ivybridge-chromeos-toolkit](https://github.com/PauloMagraniVieira/ivybridge-chromeos-toolkit)**
