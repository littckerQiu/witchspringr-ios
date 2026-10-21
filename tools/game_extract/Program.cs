// Game package → the ExeFS and RomFS a port needs.
// Usage: game_extract <prod.keys> <out dir> <package>... [--title-keys <title.keys>] [--program <id>]
// Packages are .nsp and .xci files in any mix (base game, updates, add-on content), recognised by their contents, not their names. A file over
// 4 GiB that nxdumptool wrote to the SD card is a folder holding the parts 00, 01, … (Horizon's split file): give the folder.
// The base game comes from the packages' content meta (cnmt); when they hold several, --program <id> picks one. Its newest update is layered
// on top: <out dir>/ExeFS is the update's, <out dir>/RomFS the merged view. <out dir> must not exist; it is written as <out dir>.part and
// renamed when complete. Every read is checked against the NCA hash trees, so a damaged dump fails instead of giving a damaged RomFS.
// Keys: only the keys LibHac classes as common to all consoles are taken from prod.keys; the console-unique ones (device_key, bis_key_*,
// eticket_rsa_keypair, …) are skipped unparsed. Title keys come from the common tickets in the packages, or from --title-keys. A personalized
// ticket (an eShop title dumped without nxdumptool's "tik: remove console specific data") cannot be used. Key values are never printed or
// written (never format a LibHac key struct: its ToString prints the key).
// Written after nxnative's nx_extract (seedds, MIT); the containers are read with LibHac 0.19.0 (Alex Barney, MIT).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Spl;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.FsSystem.RomFs;
using LibHac.Tools.Ncm;
using ContentType = LibHac.Ncm.ContentType;
using Path = System.IO.Path;

static class P {
    sealed class Fail : Exception { public Fail(string m) : base(m) { } }
    const IntegrityCheckLevel Check = IntegrityCheckLevel.ErrorOnInvalid;

    static int Main(string[] argv) {
        var a = new List<string>(argv);
        string titleKeys = Opt(a, "--title-keys"), program = Opt(a, "--program");
        if (a.Count < 3 || a.Any(s => s.StartsWith("--"))) {
            Console.Error.WriteLine("usage: game_extract <prod.keys> <out dir> <package>... [--title-keys <title.keys>] [--program <id>]");
            return 2;
        }
        string outDir = Path.GetFullPath(a[1].TrimEnd('/')), part = outDir + ".part";
        bool wrote = false;
        try {
            if (Directory.Exists(outDir) || File.Exists(outDir)) throw new Fail($"{outDir} exists already; move it away to extract again");
            if (Directory.Exists(part) || File.Exists(part)) throw new Fail($"{part} is left from an interrupted run; delete it first");
            KeySet ks = Keys(a[0], titleKeys);
            var ncas = new Dictionary<string, Nca>();
            var personalized = new HashSet<string>();
            foreach (string p in a.Skip(2)) Open(ks, p, ncas, personalized);

            var metas = ncas.Values.Where(n => n.Header.ContentType == NcaContentType.Meta).Select(Meta).ToList();
            var apps = metas.Where(m => m.Type == ContentMetaType.Application).ToList();
            ulong appId = program != null ? Convert.ToUInt64(program, 16)
                : apps.Count == 1 ? apps[0].TitleId
                : throw new Fail(apps.Count == 0 ? "the packages hold no base game (no application content meta)"
                                                 : $"the packages hold several base games ({string.Join(", ", apps.Select(m => $"{m.TitleId:X16}"))}); pick one with --program");
            Cnmt app = apps.FirstOrDefault(m => m.TitleId == appId) ?? throw new Fail($"the packages hold no base game {appId:X16}");
            Cnmt upd = metas.Where(m => m.Type == ContentMetaType.Patch && m.ApplicationTitleId == appId).OrderByDescending(m => m.TitleVersion.Version).FirstOrDefault();
            Nca baseProg = Content(ks, app, ContentType.Program, ncas, personalized, true);
            Nca updProg = upd == null ? null : Content(ks, upd, ContentType.Program, ncas, personalized, true);
            Nca ctrl = Content(ks, upd ?? app, ContentType.Control, ncas, personalized, false);
            Console.WriteLine($"base game {app.TitleId:X16} v{app.TitleVersion.Version}, " + (upd == null ? "no update" : $"update {upd.TitleId:X16} v{upd.TitleVersion.Version}") +
                              $", display version {(ctrl == null ? "unknown" : DisplayVersion(ctrl))}");

            wrote = true;
            IFileSystem exefs = updProg != null ? baseProg.OpenFileSystemWithPatch(updProg, NcaSectionType.Code, Check) : baseProg.OpenFileSystem(NcaSectionType.Code, Check);
            Copy(exefs, Path.Combine(part, "ExeFS"), "ExeFS");
            BuildIds(Path.Combine(part, "ExeFS"));
            IStorage romfs = updProg != null ? baseProg.OpenStorageWithPatch(updProg, NcaSectionType.Data, Check) : baseProg.OpenStorage(NcaSectionType.Data, Check);
            Copy(new RomFsFileSystem(romfs), Path.Combine(part, "RomFS"), "RomFS");
            Directory.Move(part, outDir);
            Console.WriteLine($"done: {outDir}");
            return 0;
        } catch (Exception e) {
            Console.Error.WriteLine("game_extract: " + (e is Fail ? e.Message : $"{e.GetType().Name}: {e.Message}"));
            if (wrote && Directory.Exists(part)) Directory.Delete(part, true);
            return 1;
        }
    }

    static string Opt(List<string> a, string name) {
        int i = a.IndexOf(name);
        if (i < 0) return null;
        if (i + 1 >= a.Count) throw new ArgumentException($"{name} needs a value");
        string v = a[i + 1]; a.RemoveRange(i, 2);
        return v;
    }

    // prod.keys → a key set with only the keys common to all consoles (LibHac's own classification), plus the title keys file if given
    static KeySet Keys(string prodKeys, string titleKeys) {
        List<KeyInfo> common = KeySet.CreateKeyInfoList().Where(k => (k.Type & KeyInfo.KeyType.Device) == 0).ToList();
        var kept = new StringBuilder();
        int nKept = 0, nSkipped = 0;
        foreach (string line in File.ReadLines(prodKeys)) {
            int sep = line.IndexOfAny(new[] { '=', ',' });
            if (sep <= 0) continue;
            string name = line[..sep].Trim().ToLowerInvariant();
            if (common.Any(k => k.Matches(name, out _, out bool dev) && !dev)) { kept.AppendLine(line); nKept++; } else nSkipped++;
        }
        var ks = new KeySet();
        using (var s = new MemoryStream(Encoding.UTF8.GetBytes(kept.ToString()))) ExternalKeyReader.ReadMainKeys(ks, s, common, null);
        kept.Clear();
        ks.DeriveKeys(null);
        if (ks.HeaderKey.IsZeros()) throw new Fail($"{prodKeys}: no header_key (and nothing to derive it from)");
        int nTitle = 0;
        if (titleKeys != null) {
            using (var s = File.OpenRead(titleKeys)) ExternalKeyReader.ReadTitleKeys(ks, s, null);
            nTitle = ks.ExternalKeySet.ToList().Count;
        }
        Console.WriteLine($"{Path.GetFileName(prodKeys)}: {nKept} common keys read, {nSkipped} other lines skipped (console-unique or unknown)" +
                          (titleKeys != null ? $"; {Path.GetFileName(titleKeys)}: {nTitle} title keys" : ""));
        return ks;
    }

    // One package (NSP or XCI; a file, or a split-file folder): import its common tickets, collect its NCAs by content ID
    static void Open(KeySet ks, string path, Dictionary<string, Nca> ncas, HashSet<string> personalized) {
        IStorage st = Directory.Exists(path) ? Split(path) : File.Exists(path) ? new LocalStorage(path, FileAccess.Read) : throw new Fail($"{path}: no such file or folder");
        st.GetSize(out long size).ThrowIfFailure();
        byte[] head = new byte[0x1104];
        st.Read(0, head.AsSpan(0, (int)Math.Min(head.Length, size))).ThrowIfFailure();
        IFileSystem fs; string kind;
        if (head.AsSpan(0, 4).SequenceEqual("PFS0"u8)) {
            var pfs = new PartitionFileSystem();
            pfs.Initialize(st).ThrowIfFailure();
            fs = pfs; kind = "NSP";
        } else if (head.AsSpan(0x100, 4).SequenceEqual("HEAD"u8)) {
            var xci = new Xci(ks, st);
            if (!xci.HasPartition(XciPartitionType.Secure)) throw new Fail($"{path}: the XCI has no secure partition");
            fs = xci.OpenPartition(XciPartitionType.Secure); kind = "XCI";
        } else if (head.AsSpan(0x1100, 4).SequenceEqual("HEAD"u8)) {
            throw new Fail($"{path}: an XCI with the key area in front; dump it again without nxdumptool's \"prepend key area\"");
        } else throw new Fail($"{path}: neither an NSP (PFS0) nor an XCI (HEAD at 0x100)");
        int nNca = 0, nTik = 0;
        foreach (DirectoryEntryEx e in fs.EnumerateEntries("*", SearchOptions.Default)) {
            if (e.Type != DirectoryEntryType.File) continue;
            bool tik = e.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase), nca = e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase);
            if (!tik && !nca) continue;
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            IStorage fst = f.Release().AsStorage();
            if (tik) { Ticket(ks, e.Name, fst, personalized); nTik++; }
            else { ncas[e.Name[..e.Name.IndexOf('.')].ToLowerInvariant()] = new Nca(ks, fst); nNca++; }
        }
        Console.WriteLine($"{Path.GetFileName(path.TrimEnd('/'))}: {kind}, {nNca} NCAs, {nTik} tickets");
    }

    // Horizon's split file as nxdumptool leaves it on the SD card: a folder of parts named 00, 01, … read back to back
    static IStorage Split(string dir) {
        var parts = new List<IStorage>();
        for (int i = 0; File.Exists(Path.Combine(dir, $"{i:D2}")); i++) parts.Add(new LocalStorage(Path.Combine(dir, $"{i:D2}"), FileAccess.Read));
        if (parts.Count == 0) throw new Fail($"{dir}: a folder, but not a split file (no part 00)");
        int files = Directory.GetFiles(dir).Count(f => !Path.GetFileName(f).StartsWith('.'));
        if (files != parts.Count) throw new Fail($"{dir}: {files} files, but only the parts 00–{parts.Count - 1:D2} follow each other");
        return new ConcatenationStorage(parts, false);
    }

    // A ticket's title key. Layout of signature type 0x10004 (RSA-2048, SHA-256): title key block at 0x180, title key type at 0x281
    // (0 common, 1 personalized), rights ID at 0x2A0. Only common tickets can be used; their encrypted key goes to LibHac as is.
    static void Ticket(KeySet ks, string name, IStorage st, HashSet<string> personalized) {
        byte[] t = new byte[0x2C0];
        st.GetSize(out long n).ThrowIfFailure();
        if (n < t.Length) throw new Fail($"{name}: a ticket of {n} bytes is too short");
        st.Read(0, t).ThrowIfFailure();
        uint sig = BitConverter.ToUInt32(t, 0);
        if (sig != 0x10004) throw new Fail($"{name}: ticket signature type {sig:x}, only 10004 (RSA-2048, SHA-256) is known");
        if (t[0x281] != 0) { personalized.Add(Convert.ToHexString(t, 0x2A0, 16).ToLowerInvariant()); return; }
        ks.ExternalKeySet.Add(new RightsId(t.AsSpan(0x2A0, 16)), new AccessKey(t.AsSpan(0x180, 16))).ThrowIfFailure();
    }

    // The .cnmt file in a meta NCA
    static Cnmt Meta(Nca n) {
        IFileSystem fs = n.OpenFileSystem(0, Check);
        foreach (DirectoryEntryEx e in fs.EnumerateEntries("*.cnmt", SearchOptions.Default)) return new Cnmt(new MemoryStream(Read(fs, e.FullPath)));
        throw new Fail("a meta NCA without a .cnmt file");
    }

    // The NCA of one content type of a title, checked for its title key
    static Nca Content(KeySet ks, Cnmt m, ContentType type, Dictionary<string, Nca> ncas, HashSet<string> personalized, bool required) {
        string title = $"{m.TitleId:X16} v{m.TitleVersion.Version}";
        CnmtContentEntry c = m.ContentEntries.FirstOrDefault(x => x.Type == type);
        if (c == null) return required ? throw new Fail($"{title} lists no {type} content") : null;
        string id = Convert.ToHexString(c.NcaId).ToLowerInvariant();
        if (!ncas.TryGetValue(id, out Nca nca)) return required ? throw new Fail($"{title}: its {type} NCA {id} is not in the packages") : null;
        if (nca.Header.HasRightsId) {
            string rights = Convert.ToHexString(nca.Header.RightsId).ToLowerInvariant();
            if (!ks.ExternalKeySet.Contains(new RightsId(nca.Header.RightsId))) {
                if (!required) return null;
                throw new Fail(personalized.Contains(rights)
                    ? $"{title}: its ticket is personalized (console-specific); dump the NSP again with nxdumptool's \"tik: remove console specific data\" on"
                    : $"{title}: no ticket for rights ID {rights} in the packages; give the title key with --title-keys");
            }
        }
        return nca;
    }

    // Display version from the control data (NACP offset 0x3060, 16 bytes)
    static string DisplayVersion(Nca ctrl) {
        byte[] nacp = Read(ctrl.OpenFileSystem(NcaSectionType.Data, Check), "/control.nacp");
        return nacp.Length < 0x3070 ? "unknown" : Encoding.ASCII.GetString(nacp, 0x3060, 0x10).TrimEnd('\0');
    }

    static byte[] Read(IFileSystem fs, string path) {
        using var f = new UniqueRef<IFile>();
        fs.OpenFile(ref f.Ref, path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
        f.Get.GetSize(out long n).ThrowIfFailure();
        byte[] v = new byte[n];
        f.Get.Read(out long got, 0, v, ReadOption.None).ThrowIfFailure();
        if (got != n) throw new IOException($"{path}: read {got} of {n} bytes");
        return v;
    }

    // Writes every file and folder of fs under dst, with a progress line per GiB
    static void Copy(IFileSystem fs, string dst, string label) {
        var entries = fs.EnumerateEntries("*", SearchOptions.RecurseSubdirectories).ToList();
        long total = entries.Where(e => e.Type == DirectoryEntryType.File).Sum(e => e.Size), done = 0, nextReport = 1L << 30;
        int files = 0;
        byte[] buf = new byte[8 << 20];
        Directory.CreateDirectory(dst);
        foreach (DirectoryEntryEx e in entries) {
            string op = Path.Combine(dst, e.FullPath.TrimStart('/'));
            if (e.Type == DirectoryEntryType.Directory) { Directory.CreateDirectory(op); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(op));
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            using var o = File.Create(op);
            for (long off = 0; off < e.Size;) {
                f.Get.Read(out long got, off, buf.AsSpan(0, (int)Math.Min(buf.Length, e.Size - off)), ReadOption.None).ThrowIfFailure();
                if (got <= 0) throw new IOException($"{label}{e.FullPath}: no data at offset {off}");
                o.Write(buf, 0, (int)got); off += got; done += got;
                if (done >= nextReport) { Console.WriteLine($"  {label}: {done / (double)(1L << 30):F1} / {total / (double)(1L << 30):F1} GiB"); nextReport += 1L << 30; }
            }
            files++;
        }
        Console.WriteLine($"{label}: {files} files, {total} bytes");
    }

    // Build ID of every NSO module (header bytes 0x40–0x4f, as in game.json main_build_id)
    static void BuildIds(string exefs) {
        foreach (string p in Directory.GetFiles(exefs).OrderBy(x => x, StringComparer.Ordinal)) {
            byte[] h = new byte[0x50];
            using (var f = File.OpenRead(p)) if (f.Read(h, 0, h.Length) < h.Length) continue;
            if (h.AsSpan(0, 4).SequenceEqual("NSO0"u8)) Console.WriteLine($"  {Path.GetFileName(p)} build {Convert.ToHexString(h, 0x40, 16).ToLowerInvariant()}");
        }
    }
}
