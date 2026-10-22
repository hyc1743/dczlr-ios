// Ghidra headless evidence export. Static analysis only; the target is not run.
//@category PortLab
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class ExportPortEvidence extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) throw new IllegalArgumentException("expected output directory");
        File out = new File(args[0]);
        if (!out.isAbsolute()) throw new IllegalArgumentException("output must be absolute");
        if (!out.exists() && !out.mkdirs()) throw new IllegalStateException("cannot create output");
        try (PrintWriter functions = new PrintWriter(new FileWriter(new File(out, "functions.tsv"), false));
             PrintWriter symbols = new PrintWriter(new FileWriter(new File(out, "symbols.tsv"), false))) {
            functions.println("entry\tname\tbody_bytes");
            FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
            while (iterator.hasNext() && !monitor.isCancelled()) {
                Function function = iterator.next();
                functions.printf("%s\t%s\t%d%n", function.getEntryPoint(), function.getName(), function.getBody().getNumAddresses());
            }
            symbols.println("address\tname\tsource\tkind");
            SymbolIterator symbolIterator = currentProgram.getSymbolTable().getAllSymbols(true);
            while (symbolIterator.hasNext() && !monitor.isCancelled()) {
                Symbol symbol = symbolIterator.next();
                String name = symbol.getName();
                if (name == null || !interesting(name)) continue;
                symbols.printf("%s\t%s\t%s\t%s%n", symbol.getAddress(), name, symbol.getSource(), symbol.getSymbolType());
            }
        }
        println("Exported static port evidence to " + out.getAbsolutePath());
    }

    private boolean interesting(String name) {
        String value = name.toLowerCase();
        return value.contains("direct3d") || value.contains("d3dx") || value.contains("directinput")
            || value.contains("loadresource") || value.contains("findresource") || value.contains("lockresource")
            || value.contains("createwindow") || value.contains("present") || value.contains("mmio")
            || value.contains("timebegin") || value.contains("wave") || value.contains("coinitialize")
            || value.contains("cocreateinstance") || value.contains("winmain") || value.contains("main");
    }
}
