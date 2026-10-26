// List analyzed functions in an address range as TSV.
//@category PortLab
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class ListFunctionsRange extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3) throw new IllegalArgumentException("output file, first address, last address required");
        File out = new File(args[0]);
        if (!out.isAbsolute()) throw new IllegalArgumentException("absolute output required");
        if (!out.getParentFile().exists() && !out.getParentFile().mkdirs())
            throw new IllegalStateException("cannot create output parent");
        long first = toAddr(args[1]).getOffset();
        long last = toAddr(args[2]).getOffset();
        try (PrintWriter writer = new PrintWriter(new FileWriter(out, false))) {
            writer.println("entry\tsize");
            FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
            for (Function function : functions) {
                long entry = function.getEntryPoint().getOffset();
                if (entry >= first && entry <= last)
                    writer.printf("%08x\t%d%n", entry, function.getBody().getNumAddresses());
            }
        }
    }
}
