package cn.jingzhuan.lib.office;

import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

public final class OfficeCacheChecks {
    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("abandon")) {
            OfficeCache.Entry entry = OfficeCache.create(new File(args[1]));
            Files.write(entry.getFile().toPath(), new byte[43]);
            Runtime.getRuntime().halt(0);
        }
        Path root = Files.createTempDirectory("office-cache-checks-");
        try {
            checkActiveReads(root.resolve("active").toFile());
            checkRecovery(root.resolve("recovery").toFile());
            checkConcurrentClear(root.resolve("concurrent").toFile());
            checkFailureAndIsolation(root.resolve("failure").toFile());
            System.out.println("PASS cache: active writes/reads, cleanup counts, repeated clear, process recovery, concurrent clear, scope and failure reporting");
        } finally {
            try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
                paths.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete());
            }
        }
    }

    private static void checkActiveReads(File root) throws Exception {
        OfficeCache.Entry download = OfficeCache.create(root);
        File file = download.getFile();
        Files.write(file.toPath(), new byte[] {1, 2, 3, 4});
        OfficeCache.ClearResult result = OfficeCache.clear(root);
        check(result.skippedFiles == 1 && result.deletedBytes == 0 && file.exists(), "Active download survives clear");
        try (InputStream reader = OfficeCache.openInput(file)) {
            download.close();
            download.close();
            check(file.exists() && OfficeCache.clear(root).skippedFiles == 1, "Copy retains cancelled download");
            check(reader.read() == 1 && reader.read() == 2, "Copy can still read after owner cancellation");
        }
        check(!file.exists(), "Last reader releases temporary file");
        OfficeCache.Entry shared = OfficeCache.create(root);
        File sharedFile = shared.getFile();
        Files.write(sharedFile.toPath(), new byte[] {7, 8, 9});
        OfficeCache.Entry retained = OfficeCache.retain(sharedFile);
        check(retained != null && retained.getFile().equals(sharedFile), "Active entry is retained without copying");
        shared.close();
        check(sharedFile.exists() && OfficeCache.clear(root).skippedFiles == 1, "Retained entry survives original owner close");
        retained.close();
        check(!sharedFile.exists(), "Closing retained entry deletes file");
        File leakedFile = allocateUnclosedEntry(root);
        for (int attempt = 0; attempt < 20 && OfficeCache.clear(root).skippedFiles != 0; attempt++) {
            System.gc();
            System.runFinalization();
            Thread.sleep(20);
        }
        check(!leakedFile.exists(), "Garbage-collected unclosed entry is reclaimed and deleted");
        Path stale = new File(root, "office-preview/document-stale.tmp").toPath();
        Files.write(stale, new byte[29]);
        result = OfficeCache.clear(root);
        check(result.deletedFiles == 1 && result.deletedBytes == 29 && result.failedFiles == 0, "Report actual bytes and files deleted");
        result = OfficeCache.clear(root);
        check(result.deletedFiles == 0 && result.deletedBytes == 0 && result.failedFiles == 0, "Repeated clear is empty");
    }

    private static File allocateUnclosedEntry(File root) throws Exception {
        OfficeCache.Entry leaked = OfficeCache.create(root);
        File file = leaked.getFile();
        Files.write(file.toPath(), new byte[17]);
        return file;
    }

    private static void checkRecovery(File root) throws Exception {
        Process child = new ProcessBuilder(new File(System.getProperty("java.home"), "bin/java").getPath(),
            "-cp", System.getProperty("java.class.path"), OfficeCacheChecks.class.getName(), "abandon", root.getPath()).inheritIO().start();
        check(child.waitFor(10, java.util.concurrent.TimeUnit.SECONDS), "Abandoned-file process exits");
        check(child.exitValue() == 0, "Abandoned-file process succeeds");
        File directory = new File(root, "office-preview");
        check(directory.list().length == 1, "Process death leaves temporary file");
        try (OfficeCache.Entry next = OfficeCache.create(root)) {
            check(directory.list().length == 1 && next.getFile().exists(), "First use removes abandoned file and protects new file");
        }
        check(directory.list().length == 0, "Recovery completes without residue");
    }

    private static void checkConcurrentClear(File root) throws Exception {
        CountDownLatch start = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread cleaner = new Thread(() -> {
            try {
                start.await();
                for (int i = 0; i < 300; i++) check(OfficeCache.clear(root).failedFiles == 0, "Concurrent clear succeeds");
            } catch (Throwable error) { failure.set(error); }
        });
        cleaner.start();
        start.countDown();
        for (int i = 0; i < 100; i++) {
            try (OfficeCache.Entry entry = OfficeCache.create(root)) {
                Files.write(entry.getFile().toPath(), new byte[] {42});
                try (InputStream reader = OfficeCache.openInput(entry.getFile())) {
                    check(reader.read() == 42 && entry.getFile().exists(), "Concurrent clearing preserves active data");
                }
            }
        }
        cleaner.join(10000);
        check(!cleaner.isAlive() && failure.get() == null, "Concurrent cleaner finished without failure");
        check(new File(root, "office-preview").list().length == 0, "Concurrent use leaves no files");
    }

    private static void checkFailureAndIsolation(File root) throws Exception {
        check(root.mkdirs(), "Create failure fixture");
        File directory = new File(root, "office-preview");
        Files.write(directory.toPath(), new byte[] {1});
        check(OfficeCache.clear(root).failedFiles == 1, "Report unlistable cache directory");
        Files.delete(directory.toPath());
        try (OfficeCache.Entry entry = OfficeCache.create(root)) {
            Path unrelated = new File(root, "unrelated.tmp").toPath();
            Path foreign = new File(directory, "foreign.tmp").toPath();
            Path link = new File(directory, "document-link.tmp").toPath();
            Files.write(unrelated, new byte[] {9});
            Files.write(foreign, new byte[] {8});
            Files.createSymbolicLink(link, unrelated);
            OfficeCache.clear(root);
            check(Files.exists(unrelated) && Files.exists(foreign) && Files.exists(link), "Do not traverse unrelated files or symbolic links");
            check(entry.getFile().exists(), "Active document unaffected by unrelated files");
        }
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
