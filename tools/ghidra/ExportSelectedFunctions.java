// Export explicit functions from an existing local static-analysis project.
//@category PortLab
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class ExportSelectedFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) throw new IllegalArgumentException("output directory and explicit addresses required");
        File out = new File(args[0]);
        if (!out.isAbsolute()) throw new IllegalArgumentException("absolute output required");
        if (!out.exists() && !out.mkdirs()) throw new IllegalStateException("cannot create output");
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException("cannot open decompiler");
            for (int i = 1; i < args.length && !monitor.isCancelled(); ++i) {
                Address address = toAddr(args[i]);
                Function function = getFunctionContaining(address);
                if (function == null) function = getFunctionAt(address);
                if (function == null) throw new IllegalArgumentException("no analyzed function at " + address);
                String stem = function.getEntryPoint().toString();
                DecompileResults result = decompiler.decompileFunction(function, 90, monitor);
                if (!result.decompileCompleted()) throw new IllegalStateException(result.getErrorMessage());
                try (PrintWriter c = new PrintWriter(new FileWriter(new File(out, stem + ".c"), false));
                     PrintWriter assembly = new PrintWriter(new FileWriter(new File(out, stem + ".asm"), false));
                     PrintWriter calls = new PrintWriter(new FileWriter(new File(out, stem + ".calls.tsv"), false));
                     PrintWriter references = new PrintWriter(new FileWriter(new File(out, stem + ".refs.tsv"), false))) {
                    c.println("// Ghidra pseudocode, not recovered original source.");
                    c.println(result.getDecompiledFunction().getC());
                    InstructionIterator instructions = currentProgram.getListing().getInstructions(function.getBody(), true);
                    while (instructions.hasNext()) {
                        Instruction instruction = instructions.next();
                        assembly.printf("%s\t%s%n", instruction.getAddress(), instruction);
                    }
                    references.println("from\tto\ttype");
                    for (Reference reference : getReferencesTo(function.getEntryPoint()))
                        references.printf("%s\t%s\t%s%n", reference.getFromAddress(), reference.getToAddress(), reference.getReferenceType());
                    calls.println("entry\tname\tbody_bytes");
                    for (Function called : function.getCalledFunctions(monitor))
                        calls.printf("%s\t%s\t%d%n", called.getEntryPoint(), called.getName(), called.getBody().getNumAddresses());
                }
                println("Exported " + function.getName() + " at " + function.getEntryPoint());
            }
        } finally {
            decompiler.dispose();
        }
    }
}
