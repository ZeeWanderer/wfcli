// Export build-keyed reverse-engineering evidence for wfinspect.
//@category wfcli

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class ExportWfinspectReport extends GhidraScript {
    private static final int SCHEMA_VERSION = 1;
    private static final int PRODUCER_VERSION = 1;
    private static final int MAX_RESULTS = 100_000;
    private static final int MAX_DECOMPILE_CHARS = 4 * 1024 * 1024;

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            throw new IllegalArgumentException(
                "expected output path followed by optional KIND=VALUE queries");
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        List<Map<String, Object>> queries = new ArrayList<>();
        try {
            for (int index = 1; index < args.length; index++) {
                queries.add(runQuery(args[index], decompiler));
            }
        } finally {
            decompiler.dispose();
        }

        Map<String, Object> report = new LinkedHashMap<>();
        report.put("schema", "wfinspect.ghidra-report");
        report.put("schema_version", SCHEMA_VERSION);
        report.put("producer", Map.of(
            "name", "ExportWfinspectReport",
            "version", PRODUCER_VERSION));
        report.put("program", programMetadata());
        report.put("queries", queries);

        Path output = Path.of(args[0]);
        if (output.getParent() != null) {
            Files.createDirectories(output.getParent());
        }
        Gson gson = new GsonBuilder().disableHtmlEscaping().setPrettyPrinting().create();
        Files.writeString(output, gson.toJson(report) + "\n", StandardCharsets.UTF_8);
        println("Exported " + queries.size() + " query result(s) to " + output);
    }

    private Map<String, Object> programMetadata() {
        Map<String, Object> program = new LinkedHashMap<>();
        program.put("name", currentProgram.getName());
        program.put("path", currentProgram.getExecutablePath());
        program.put("format", currentProgram.getExecutableFormat());
        program.put("sha256", currentProgram.getExecutableSHA256());
        program.put("image_base", currentProgram.getImageBase().toString());
        program.put("language", currentProgram.getLanguageID().toString());
        program.put("compiler", currentProgram.getCompilerSpec().getCompilerSpecID().toString());
        return program;
    }

    private Map<String, Object> runQuery(String argument, DecompInterface decompiler)
            throws Exception {
        int separator = argument.indexOf('=');
        if (separator <= 0 || separator == argument.length() - 1) {
            throw new IllegalArgumentException("invalid query: " + argument);
        }
        String kind = argument.substring(0, separator);
        String value = argument.substring(separator + 1);
        return switch (kind) {
            case "function" -> exportFunction(value, decompiler);
            case "xrefs" -> exportXrefs(value);
            case "string" -> exportString(value);
            case "scalar" -> exportScalar(value);
            case "pointers" -> exportPointers(value);
            default -> throw new IllegalArgumentException("unknown query kind: " + kind);
        };
    }

    private Map<String, Object> exportFunction(String value, DecompInterface decompiler) {
        Address requested = toAddr(value);
        Function function = getFunctionAt(requested);
        if (function == null) {
            function = getFunctionContaining(requested);
        }
        Map<String, Object> query = query("function", value);
        if (function == null) {
            query.put("found", false);
            return query;
        }

        query.put("found", true);
        query.put("entry", function.getEntryPoint().toString());
        query.put("name", function.getName());
        List<Map<String, String>> instructions = new ArrayList<>();
        InstructionIterator iterator =
            currentProgram.getListing().getInstructions(function.getBody(), true);
        while (iterator.hasNext() && instructions.size() < MAX_RESULTS && !monitor.isCancelled()) {
            Instruction instruction = iterator.next();
            instructions.add(Map.of(
                "address", instruction.getAddress().toString(),
                "text", instruction.toString()));
        }
        query.put("instructions", instructions);
        query.put("instructions_truncated", iterator.hasNext());

        DecompileResults result = decompiler.decompileFunction(function, 180, monitor);
        if (result.decompileCompleted()) {
            String source = result.getDecompiledFunction().getC();
            boolean truncated = source.length() > MAX_DECOMPILE_CHARS;
            query.put("decompilation", truncated ? source.substring(0, MAX_DECOMPILE_CHARS) : source);
            query.put("decompilation_truncated", truncated);
        } else {
            query.put("decompile_error", result.getErrorMessage());
        }
        return query;
    }

    private Map<String, Object> exportXrefs(String value) {
        Map<String, Object> query = query("xrefs", value);
        query.put("references", referencesTo(toAddr(value)));
        return query;
    }

    private Map<String, Object> exportString(String value) throws Exception {
        Map<String, Object> query = query("string", value);
        Memory memory = currentProgram.getMemory();
        byte[] needle = value.getBytes(StandardCharsets.UTF_8);
        List<Map<String, Object>> matches = new ArrayList<>();
        Address cursor = memory.getMinAddress();
        while (cursor != null && matches.size() < MAX_RESULTS && !monitor.isCancelled()) {
            Address found = memory.findBytes(cursor, needle, null, true, monitor);
            if (found == null) {
                break;
            }
            Map<String, Object> match = new LinkedHashMap<>();
            match.put("address", found.toString());
            match.put("references", referencesTo(found));
            matches.add(match);
            cursor = found.equals(memory.getMaxAddress()) ? null : found.next();
        }
        query.put("matches", matches);
        query.put("truncated", matches.size() == MAX_RESULTS);
        return query;
    }

    private Map<String, Object> exportScalar(String value) {
        long target = Long.decode(value);
        Map<String, Object> query = query("scalar", value);
        List<Map<String, Object>> matches = new ArrayList<>();
        InstructionIterator instructions = currentProgram.getListing().getInstructions(true);
        while (instructions.hasNext() && matches.size() < MAX_RESULTS && !monitor.isCancelled()) {
            Instruction instruction = instructions.next();
            for (int operand = 0; operand < instruction.getNumOperands(); operand++) {
                for (Object object : instruction.getOpObjects(operand)) {
                    if (!(object instanceof Scalar scalar)
                            || scalar.getUnsignedValue() != target) {
                        continue;
                    }
                    Map<String, Object> match = instructionRecord(instruction);
                    match.put("operand", operand);
                    matches.add(match);
                }
            }
        }
        query.put("matches", matches);
        query.put("truncated", matches.size() == MAX_RESULTS);
        return query;
    }

    private Map<String, Object> exportPointers(String value) throws Exception {
        String[] fields = value.split(":", -1);
        if (fields.length != 3) {
            throw new IllegalArgumentException(
                "pointers query requires START:COUNT:WIDTH");
        }
        Address start = toAddr(fields[0]);
        int count = Integer.decode(fields[1]);
        int width = Integer.decode(fields[2]);
        if (count < 1 || count > MAX_RESULTS || (width != 4 && width != 8)) {
            throw new IllegalArgumentException(
                "pointer count must be 1..100000 and width must be 4 or 8");
        }

        Memory memory = currentProgram.getMemory();
        List<Map<String, Object>> entries = new ArrayList<>();
        for (int index = 0; index < count; index++) {
            Address slot = start.add((long) index * width);
            long raw;
            Address target;
            if (width == 4) {
                raw = Integer.toUnsignedLong(memory.getInt(slot));
                target = currentProgram.getImageBase().add(raw);
            } else {
                raw = memory.getLong(slot);
                target = toAddr(raw);
            }
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("index", index);
            entry.put("slot", slot.toString());
            entry.put("raw", String.format("0x%x", raw));
            entry.put("target", target.toString());
            Function function = getFunctionAt(target);
            if (function != null) {
                entry.put("function", function.getName());
            }
            entries.add(entry);
        }
        Map<String, Object> query = query("pointers", value);
        query.put("entries", entries);
        return query;
    }

    private List<Map<String, Object>> referencesTo(Address target) {
        List<Map<String, Object>> references = new ArrayList<>();
        ReferenceIterator iterator = currentProgram.getReferenceManager().getReferencesTo(target);
        while (iterator.hasNext() && references.size() < MAX_RESULTS && !monitor.isCancelled()) {
            Reference reference = iterator.next();
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("from", reference.getFromAddress().toString());
            result.put("type", reference.getReferenceType().toString());
            Function function = getFunctionContaining(reference.getFromAddress());
            if (function != null) {
                result.put("function_entry", function.getEntryPoint().toString());
                result.put("function", function.getName());
            }
            references.add(result);
        }
        return references;
    }

    private Map<String, Object> instructionRecord(Instruction instruction) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("address", instruction.getAddress().toString());
        result.put("text", instruction.toString());
        Function function = getFunctionContaining(instruction.getAddress());
        if (function != null) {
            result.put("function_entry", function.getEntryPoint().toString());
            result.put("function", function.getName());
        }
        return result;
    }

    private Map<String, Object> query(String kind, String input) {
        Map<String, Object> query = new LinkedHashMap<>();
        query.put("kind", kind);
        query.put("input", input);
        return query;
    }
}
