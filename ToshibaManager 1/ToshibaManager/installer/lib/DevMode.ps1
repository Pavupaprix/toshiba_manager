<#
    DevMode.ps1 — lecture et application du DEVMODE d'une file d'impression.

    Les options propres au pilote Toshiba (impression intelligente, mode couleur
    Toshiba, agrafage, etc.) vivent dans la partie privee du DEVMODE et ne sont
    pas accessibles aux cmdlets PrintManagement. On passe donc par winspool.drv.

    Fonctions exposees :
      Export-PrinterDevMode  -PrinterName <nom> -Path <fichier.bin>
      Import-PrinterDevMode  -PrinterName <nom> -Path <fichier.bin>
      Sync-PrinterUserDefaults -PrinterName <nom>

    Windows conserve deux jeux de reglages distincts par file :
      - « Parametres par defaut de l'impression » : niveau machine, commun a
        tous les utilisateurs, seul jeu atteint par Set-PrintConfiguration ;
      - « Preferences d'impression » : niveau utilisateur, celui reellement
        utilise lors d'une impression.
    Sync-PrinterUserDefaults recopie le premier dans le second.
#>

Set-StrictMode -Version Latest

function Initialize-DevModeInterop {
    if ('OMB.PrinterDevMode' -as [type]) { return }

    $source = @'
using System;
using System.Runtime.InteropServices;

namespace OMB
{
    public static class PrinterDevMode
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PRINTER_DEFAULTS
        {
            public IntPtr pDatatype;
            public IntPtr pDevMode;
            public int DesiredAccess;
        }

        [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, ref PRINTER_DEFAULTS pDefault);

        [DllImport("winspool.drv", SetLastError = true)]
        private static extern bool ClosePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "DocumentPropertiesW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int DocumentProperties(IntPtr hWnd, IntPtr hPrinter, string pDeviceName, IntPtr pDevModeOutput, IntPtr pDevModeInput, int fMode);

        [DllImport("winspool.drv", EntryPoint = "GetPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int cbBuf, out int pcbNeeded);

        [DllImport("winspool.drv", EntryPoint = "SetPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int Command);

        private const int PRINTER_ACCESS_USE = 0x00000008;
        private const int PRINTER_ACCESS_ADMINISTER = 0x00000004;
        private const int STANDARD_RIGHTS_REQUIRED = 0x000F0000;
        private const int PRINTER_ALL_ACCESS = STANDARD_RIGHTS_REQUIRED | PRINTER_ACCESS_ADMINISTER | PRINTER_ACCESS_USE;

        private const int DM_OUT_BUFFER = 2;
        private const int DM_IN_BUFFER = 8;

        // Decalages dans PRINTER_INFO_2, exprimes en nombre de pointeurs.
        private const int PI2_DEVMODE_INDEX = 7;
        private const int PI2_SECURITY_INDEX = 12;

        // CCHDEVICENAME : dmDeviceName occupe les 32 premiers WCHAR du DEVMODE.
        private const int CCHDEVICENAME = 32;

        private static IntPtr Open(string printer, int access)
        {
            PRINTER_DEFAULTS defaults = new PRINTER_DEFAULTS();
            defaults.pDatatype = IntPtr.Zero;
            defaults.pDevMode = IntPtr.Zero;
            defaults.DesiredAccess = access;

            IntPtr handle;
            if (!OpenPrinter(printer, out handle, ref defaults))
            {
                throw new Exception("OpenPrinter a echoue pour '" + printer + "' (code " + Marshal.GetLastWin32Error() + ").");
            }
            return handle;
        }

        private static int RequiredSize(IntPtr handle, string printer)
        {
            int size = DocumentProperties(IntPtr.Zero, handle, printer, IntPtr.Zero, IntPtr.Zero, 0);
            if (size <= 0)
            {
                throw new Exception("DocumentProperties a renvoye une taille de DEVMODE invalide (" + size + ") pour '" + printer + "'.");
            }
            return size;
        }

        // Aligne dmDeviceName sur l'imprimante cible : un DEVMODE capture sur une
        // autre file porte encore le nom de la file d'origine.
        private static void WriteDeviceName(IntPtr devmode, string name)
        {
            char[] buffer = new char[CCHDEVICENAME];
            int count = Math.Min(name.Length, CCHDEVICENAME - 1);
            for (int i = 0; i < count; i++) { buffer[i] = name[i]; }
            Marshal.Copy(buffer, 0, devmode, CCHDEVICENAME);
        }

        private static byte[] ReadDevModeAt(IntPtr pDevMode, string printer)
        {
            if (pDevMode == IntPtr.Zero)
            {
                throw new Exception("La file '" + printer + "' n'expose aucun DEVMODE a ce niveau.");
            }

            int dmSize = Marshal.ReadInt16(pDevMode, 68) & 0xFFFF;
            int dmDriverExtra = Marshal.ReadInt16(pDevMode, 70) & 0xFFFF;
            int total = dmSize + dmDriverExtra;
            if (total < 72)
            {
                throw new Exception("DEVMODE incoherent pour '" + printer + "' (" + total + " octets).");
            }

            byte[] data = new byte[total];
            Marshal.Copy(pDevMode, data, 0, total);
            return data;
        }

        // Lit le DEVMODE « Parametres par defaut de l'impression ».
        //
        // PRINTER_INFO_8 est le seul niveau qui expose reellement le defaut
        // machine : GetPrinter niveau 2 renvoie le DEVMODE deja fusionne avec
        // les preferences de l'utilisateur courant, donc jamais la valeur
        // stockee sous HKLM.
        public static byte[] ExportPrinterDefaults(string printer)
        {
            IntPtr handle = Open(printer, PRINTER_ACCESS_USE);
            IntPtr info = IntPtr.Zero;
            try
            {
                int needed;
                GetPrinter(handle, 8, IntPtr.Zero, 0, out needed);
                if (needed > 0)
                {
                    info = Marshal.AllocHGlobal(needed);
                    if (GetPrinter(handle, 8, info, needed, out needed))
                    {
                        IntPtr global = Marshal.ReadIntPtr(info, 0);
                        if (global != IntPtr.Zero)
                        {
                            return ReadDevModeAt(global, printer);
                        }
                    }
                    Marshal.FreeHGlobal(info);
                    info = IntPtr.Zero;
                }

                // Aucun defaut global defini : on retombe sur le niveau 2.
                GetPrinter(handle, 2, IntPtr.Zero, 0, out needed);
                if (needed <= 0)
                {
                    throw new Exception("GetPrinter niveau 2 n'a pas renvoye de taille pour '" + printer + "'.");
                }
                info = Marshal.AllocHGlobal(needed);
                if (!GetPrinter(handle, 2, info, needed, out needed))
                {
                    throw new Exception("GetPrinter niveau 2 a echoue (code " + Marshal.GetLastWin32Error() + ").");
                }
                return ReadDevModeAt(Marshal.ReadIntPtr(info, PI2_DEVMODE_INDEX * IntPtr.Size), printer);
            }
            finally
            {
                if (info != IntPtr.Zero) { Marshal.FreeHGlobal(info); }
                ClosePrinter(handle);
            }
        }

        public static byte[] Export(string printer)
        {
            IntPtr handle = Open(printer, PRINTER_ACCESS_USE);
            IntPtr buffer = IntPtr.Zero;
            try
            {
                int size = RequiredSize(handle, printer);
                buffer = Marshal.AllocHGlobal(size);
                int result = DocumentProperties(IntPtr.Zero, handle, printer, buffer, IntPtr.Zero, DM_OUT_BUFFER);
                if (result != 1)
                {
                    throw new Exception("Lecture du DEVMODE impossible pour '" + printer + "' (retour " + result + ").");
                }
                byte[] data = new byte[size];
                Marshal.Copy(buffer, data, 0, size);
                return data;
            }
            finally
            {
                if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); }
                ClosePrinter(handle);
            }
        }

        // machineDefaults = true  : defauts de l'imprimante (PRINTER_INFO_2), requiert l'elevation.
        // machineDefaults = false : defauts de l'utilisateur courant (PRINTER_INFO_9).
        public static void Apply(string printer, byte[] devmode, bool machineDefaults)
        {
            if (devmode == null || devmode.Length < 72)
            {
                throw new Exception("Le DEVMODE fourni est trop court pour etre valide (" + (devmode == null ? 0 : devmode.Length) + " octets).");
            }

            IntPtr handle = Open(printer, machineDefaults ? PRINTER_ALL_ACCESS : PRINTER_ACCESS_USE);
            IntPtr inBuffer = IntPtr.Zero;
            IntPtr outBuffer = IntPtr.Zero;
            IntPtr info = IntPtr.Zero;
            try
            {
                inBuffer = Marshal.AllocHGlobal(devmode.Length);
                Marshal.Copy(devmode, 0, inBuffer, devmode.Length);
                WriteDeviceName(inBuffer, printer);

                // DM_IN_BUFFER | DM_OUT_BUFFER : le pilote valide et normalise le
                // DEVMODE de reference avant qu'on ne l'ecrive.
                int size = RequiredSize(handle, printer);
                outBuffer = Marshal.AllocHGlobal(size);
                int result = DocumentProperties(IntPtr.Zero, handle, printer, outBuffer, inBuffer, DM_IN_BUFFER | DM_OUT_BUFFER);
                if (result != 1)
                {
                    throw new Exception("Le pilote a refuse le DEVMODE de reference pour '" + printer + "' (retour " + result + ").");
                }

                // Niveau 8 = PRINTER_INFO_8, le defaut global de la file.
                // Niveau 9 = PRINTER_INFO_9, les preferences de l'utilisateur.
                // Le niveau 2 ne convient pas pour le defaut global : des qu'un
                // DEVMODE par utilisateur existe, le spouleur y detourne
                // l'ecriture et HKLM reste inchange.
                int niveau = machineDefaults ? 8 : 9;
                info = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(info, 0, outBuffer);
                if (!SetPrinter(handle, niveau, info, 0))
                {
                    throw new Exception("SetPrinter niveau " + niveau + " a echoue (code " + Marshal.GetLastWin32Error() + ").");
                }
            }
            finally
            {
                if (info != IntPtr.Zero) { Marshal.FreeHGlobal(info); }
                if (outBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(outBuffer); }
                if (inBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(inBuffer); }
                ClosePrinter(handle);
            }
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Export-PrinterDevMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrinterName,
        [Parameter(Mandatory)][string]$Path
    )

    Initialize-DevModeInterop
    $data = [OMB.PrinterDevMode]::Export($PrinterName)

    $dossier = Split-Path -Parent $Path
    if ($dossier -and -not (Test-Path -LiteralPath $dossier)) {
        New-Item -ItemType Directory -Path $dossier -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, $data)
    return $data.Length
}

function Import-PrinterDevMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrinterName,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Fichier DEVMODE introuvable : $Path"
    }

    Initialize-DevModeInterop
    $data = [System.IO.File]::ReadAllBytes($Path)

    # Defauts machine d'abord (visibles par tous les utilisateurs du poste),
    # puis defauts de l'utilisateur courant qui priment a l'impression.
    [OMB.PrinterDevMode]::Apply($PrinterName, $data, $true)
    [OMB.PrinterDevMode]::Apply($PrinterName, $data, $false)
}

function Sync-PrinterUserDefaults {
    <#
        Recopie « Parametres par defaut de l'impression » (niveau machine) dans
        « Preferences d'impression » (niveau utilisateur). Sans cela, ce que
        Set-PrintConfiguration ecrit reste invisible a l'impression pour
        l'utilisateur courant.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PrinterName)

    Initialize-DevModeInterop
    $data = [OMB.PrinterDevMode]::ExportPrinterDefaults($PrinterName)
    [OMB.PrinterDevMode]::Apply($PrinterName, $data, $false)
}

function Test-PrinterDevModeCoherence {
    <#
        Vrai si les parametres par defaut (machine) et les preferences
        d'impression (utilisateur) portent les memes reglages.

        Deux zones sont exclues de la comparaison :
          - octets 0 a 63  : dmDeviceName, qui porte le nom de la file ;
          - octets 72 a 75 : dmFields, que Windows renormalise differemment
            selon le chemin de lecture et qui differe donc toujours.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PrinterName)

    Initialize-DevModeInterop
    $machine = [OMB.PrinterDevMode]::ExportPrinterDefaults($PrinterName)
    $utilisateur = [OMB.PrinterDevMode]::Export($PrinterName)

    if ($machine.Length -ne $utilisateur.Length) { return $false }

    foreach ($plage in @(@(64, 72), @(76, $machine.Length))) {
        for ($i = $plage[0]; $i -lt $plage[1]; $i++) {
            if ($machine[$i] -ne $utilisateur[$i]) { return $false }
        }
    }
    return $true
}
