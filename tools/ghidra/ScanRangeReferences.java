// Report the functions containing any reference into an address range.
//@category PortLab
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Reference;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class ScanRangeReferences extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3) throw new IllegalArgumentException("output file, first, last address required");
        File out = new File(args[0]);
        if (!out.isAbsolute()) throw new IllegalArgumentException("absolute output required");
        long first = toAddr(args[1]).getOffset();
        long last = toAddr(args[2]).getOffset();
        FunctionManager manager = currentProgram.getFunctionManager();
        try (PrintWriter writer = new PrintWriter(new FileWriter(out, false))) {
            writer.println("function\taddress\tkind");
            InstructionIterator instructions = currentProgram.getListing().getInstructions(true);
            while (instructions.hasNext() && !monitor.isCancelled()) {
                Instruction instruction = instructions.next();
                for (Reference reference : instruction.getReferencesFrom()) {
                    long target = reference.getToAddress().getOffset();
                    if (target >= first && target <= last) {
                        Function function = manager.getFunctionContaining(instruction.getAddress());
                        writer.printf("%s\t%s\t%s%n",
                            function == null ? "none" : function.getEntryPoint(),
                            instruction.getAddress(), reference.getReferenceType());
                    }
                }
            }
        }
    }
}
