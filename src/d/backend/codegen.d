module d.backend.codegen;

import d.ast.symbol;

import util.visitor;

import llvm.c.Analysis;
import llvm.c.Core;

import std.string;

auto codeGen(ModuleSymbol m) {
	auto builder = LLVMCreateBuilder();
	auto dmodule = LLVMModuleCreateWithName(m.location.filename.toStringz());
	
	// Dump module content on failure (for debug purpose).
	scope(failure) LLVMDumpModule(dmodule);
	
	auto sdg = new SymbolDeclarationGen(builder, dmodule);
	foreach(sym; m.symbols) {
		sdg.visit(sym);
	}
	
	auto sg = new SymbolGen(builder, dmodule);
	foreach(sym; m.symbols) {
		sg.visit(sym);
	}
	
	return dmodule;
}

import d.ast.dfunction;

class SymbolDeclarationGen {
	private LLVMBuilderRef builder;
	private LLVMModuleRef dmodule;
	
	private TypeGen typeGen;
	
	this(LLVMBuilderRef builder, LLVMModuleRef dmodule) {
		this.builder = builder;
		this.dmodule = dmodule;
		
		typeGen = new TypeGen();
	}
	
final:
	void visit(Symbol s) {
		this.dispatch(s);
	}
	
	void visit(FunctionSymbol fun) {
		LLVMTypeRef[] parametersTypes;
		parametersTypes.length = fun.parameters.length;
		
		foreach(i, p; fun.parameters) {
			parametersTypes[i] = typeGen.visit(p.type);
		}
		
		auto funType = LLVMFunctionType(typeGen.visit(fun.returnType), parametersTypes.ptr, cast(uint) parametersTypes.length, false);
		LLVMAddFunction(dmodule, fun.mangling.toStringz(), funType);
	}
	
	void visit(VariableSymbol var) {
		auto globalVar = LLVMAddGlobal(dmodule, typeGen.visit(var.type), var.mangling.toStringz());
		LLVMSetThreadLocal(globalVar, true);
	}
}

class SymbolGen {
	private LLVMBuilderRef builder;
	private LLVMModuleRef dmodule;
	
	private TypeGen typeGen;
	private SymbolStatementGen symbolStatementGen;
	private ExpressionGen expressionGen;
	private StatementGen statementGen;
	
	
	this(LLVMBuilderRef builder, LLVMModuleRef dmodule) {
		this.builder = builder;
		this.dmodule = dmodule;
		
		typeGen = new TypeGen();
		symbolStatementGen = new SymbolStatementGen(builder, dmodule, typeGen);
		expressionGen = new ExpressionGen(builder, symbolStatementGen, typeGen);
		statementGen = new StatementGen(builder, symbolStatementGen, expressionGen);
	}
	
final:
	void visit(Symbol s) {
		this.dispatch(s);
	}
	
	void visit(FunctionSymbol f) {
		auto fun = LLVMGetNamedFunction(dmodule, f.mangling.toStringz());
		
		// Clear the variable table when the generation is finished.
		scope(exit) symbolStatementGen.variables.clear();
		
		// Alloca and instruction block.
		auto allocaBB = LLVMAppendBasicBlock(fun, "");
		auto bodyBB = LLVMAppendBasicBlock(fun, "body");
		
		// Handle parameters in the alloca block.
		LLVMPositionBuilderAtEnd(builder, allocaBB);
		
		LLVMValueRef[] params;
		params.length = f.parameters.length;
		LLVMGetParams(fun, params.ptr);
		
		// TODO: avoid computing that twice.
		LLVMTypeRef[] paramTypes;
		paramTypes.length = f.parameters.length;
		
		foreach(i, p; f.parameters) {
			paramTypes[i] = typeGen.visit(p.type);
		}
		
		foreach(i, p; f.parameters) {
			if(auto asNamed = cast(NamedParameter) p) {
				auto alloca = LLVMBuildAlloca(builder, paramTypes[i], asNamed.name.toStringz());
				auto value = params[i];
				
				LLVMSetValueName(value, ("arg." ~ asNamed.name).toStringz());
				
				LLVMBuildStore(builder, value, alloca);
				symbolStatementGen.variables[asNamed.name] = alloca;
			}
		}
		
		// Generate function's body.
		LLVMPositionBuilderAtEnd(builder, bodyBB);
		statementGen.visit(f.fbody);
		
		// If the current block isn' concluded, it means that it is unreachable.
		if(!LLVMGetBasicBlockTerminator(LLVMGetInsertBlock(builder))) {
			LLVMBuildUnreachable(builder);
		}
		
		// Branch from alloca block to function body.
		LLVMPositionBuilderAtEnd(builder, allocaBB);
		LLVMBuildBr(builder, bodyBB);
		
		LLVMVerifyFunction(fun, LLVMVerifierFailureAction.PrintMessage);
	}
	
	void visit(VariableSymbol var) {
		auto globalVar = LLVMGetNamedGlobal(dmodule, var.mangling.toStringz());
		
		// Store the initial value into the alloca.
		auto value = expressionGen.visit(var.value);
		LLVMSetInitializer(globalVar, value);
	}
}

class SymbolStatementGen {
	private LLVMBuilderRef builder;
	private LLVMModuleRef dmodule;
	
	private TypeGen typeGen;
	private ExpressionGen expressionGen;
	
	LLVMValueRef[string] variables;
	
	this(LLVMBuilderRef builder, LLVMModuleRef dmodule, TypeGen typeGen) {
		this.builder = builder;
		this.dmodule = dmodule;
		
		this.typeGen = typeGen;
		
		expressionGen = new ExpressionGen(builder, this, typeGen);
	}
	
final:
	void visit(Symbol s) {
		this.dispatch(s);
	}
	
	void visit(VariableSymbol var) {
		// Backup current block
		auto backupCurrentBlock = LLVMGetInsertBlock(builder);
		LLVMPositionBuilderAtEnd(builder, LLVMGetFirstBasicBlock(LLVMGetBasicBlockParent(backupCurrentBlock)));
		
		// Create an alloca for this variable.
		auto alloca = LLVMBuildAlloca(builder, typeGen.visit(var.type), var.name.toStringz());
		
		LLVMPositionBuilderAtEnd(builder, backupCurrentBlock);
		
		// Store the initial value into the alloca.
		auto value = expressionGen.visit(var.value);
		LLVMBuildStore(builder, value, alloca);
		
		variables[var.name] = alloca;
	}
}

import d.ast.statement;

class StatementGen {
	private LLVMBuilderRef builder;
	
	private SymbolStatementGen symbolStatementGen;
	private ExpressionGen expressionGen;
	
	this(LLVMBuilderRef builder, SymbolStatementGen symbolStatementGen, ExpressionGen expressionGen){
		this.builder = builder;
		this.symbolStatementGen = symbolStatementGen;
		this.expressionGen = expressionGen;
	}
	
final:
	void visit(Statement s) {
		this.dispatch(s);
	}
	
	void visit(SymbolStatement s) {
		symbolStatementGen.visit(s.symbol);
	}
	
	void visit(ExpressionStatement e) {
		expressionGen.visit(e.expression);
	}
	
	void visit(BlockStatement b) {
		foreach(s; b.statements) {
			visit(s);
		}
	}
	
	void visit(IfElseStatement ifs) {
		auto condition = expressionGen.visit(ifs.condition);
		
		auto fun = LLVMGetBasicBlockParent(LLVMGetInsertBlock(builder));
		
		auto thenBB = LLVMAppendBasicBlock(fun, "then");
		auto elseBB = LLVMAppendBasicBlock(fun, "else");
		auto mergeBB = LLVMAppendBasicBlock(fun, "merge");
		
		LLVMBuildCondBr(builder, condition, thenBB, elseBB);
		
		// Emit then
		LLVMPositionBuilderAtEnd(builder, thenBB);
		
		visit(ifs.then);
		
		// Codegen of then can change the current block, so we put everything in order.
		thenBB = LLVMGetInsertBlock(builder);
		
		// Conclude that block if it isn't already.
		if(!LLVMGetBasicBlockTerminator(thenBB)) {
			LLVMBuildBr(builder, mergeBB);
		}
		
		// Put the else block after the generated stuff.
		LLVMMoveBasicBlockAfter(elseBB, thenBB);
		LLVMPositionBuilderAtEnd(builder, elseBB);
		
		// Emit else
		visit(ifs.elseStatement);
		
		// Codegen of else can change the current block, so we put everything in order.
		elseBB = LLVMGetInsertBlock(builder);
		
		// Conclude that block if it isn't already.
		if(!LLVMGetBasicBlockTerminator(elseBB)) {
			LLVMBuildBr(builder, mergeBB);
		}
		
		LLVMMoveBasicBlockAfter(mergeBB, elseBB);
		LLVMPositionBuilderAtEnd(builder, mergeBB);
	}
	
	private void handleLoop(LoopStatement)(LoopStatement l) {
		auto fun = LLVMGetBasicBlockParent(LLVMGetInsertBlock(builder));
		
		enum isFor = is(LoopStatement : ForStatement);
		enum isDoWhile = is(LoopStatement : DoWhileStatement);
		
		static if(isFor) {
			auto testBB = LLVMAppendBasicBlock(fun, "for");
			auto continueBB = LLVMAppendBasicBlock(fun, "increment");
		} else {
			auto testBB = LLVMAppendBasicBlock(fun, "while");
			alias testBB continueBB;
		}
		
		auto doBB = LLVMAppendBasicBlock(fun, "do");
		auto doneBB = LLVMAppendBasicBlock(fun, "done");
		
		static if(isDoWhile) {
			alias doBB startBB;
		} else {
			alias testBB startBB;
		}
		
		// Generate initialization if appropriate
		static if(isFor) {
			visit(l.initialize);
		}
		
		// Jump into the loop.
		LLVMBuildBr(builder, startBB);
		LLVMPositionBuilderAtEnd(builder, testBB);
		
		// Test and do or jump to done.
		auto condition = expressionGen.visit(l.condition);
		LLVMBuildCondBr(builder, condition, doBB, doneBB);
		
		// Build continue block or alias it to the test.
		static if(isFor) {
			LLVMPositionBuilderAtEnd(builder, continueBB);
			expressionGen.visit(l.increment);
			
			LLVMBuildBr(builder, testBB);
		}
		
		// Emit do
		LLVMPositionBuilderAtEnd(builder, doBB);
		
		visit(l.statement);
		
		// Codegen of then can change the current block, so we put everything in order.
		doBB = LLVMGetInsertBlock(builder);
		
		// Conclude that block if it isn't already.
		if(!LLVMGetBasicBlockTerminator(doBB)) {
			LLVMBuildBr(builder, continueBB);
		}
		
		LLVMMoveBasicBlockAfter(doneBB, doBB);
		LLVMPositionBuilderAtEnd(builder, doneBB);
	}
	
	void visit(WhileStatement w) {
		handleLoop(w);
	}
	
	void visit(DoWhileStatement w) {
		handleLoop(w);
	}
	
	void visit(ForStatement f) {
		handleLoop(f);
	}
	
	void visit(ReturnStatement r) {
		LLVMBuildRet(builder, expressionGen.visit(r.value));
	}
}

import d.ast.expression;

class ExpressionGen {
	private LLVMBuilderRef builder;
	
	private SymbolStatementGen symbolStatementGen;
	private TypeGen typeGen;
	
	this(LLVMBuilderRef builder, SymbolStatementGen symbolStatementGen, TypeGen typeGen) {
		this.builder = builder;
		this.symbolStatementGen = symbolStatementGen;
		this.typeGen = typeGen;
	}
	
final:
	LLVMValueRef visit(Expression e) {
		return this.dispatch!(function LLVMValueRef(Expression e) {
			auto msg = typeid(e).toString() ~ " is not supported.";
			
			import sdc.terminal;
			outputCaretDiagnostics(e.location, msg);
			
			assert(0, msg);
		})(e);
	}
	
	LLVMValueRef visit(BooleanLiteral bl) {
		return LLVMConstInt(typeGen.visit(bl.type), bl.value, false);
	}
	
	LLVMValueRef visit(IntegerLiteral!true il) {
		return LLVMConstInt(typeGen.visit(il.type), il.value, true);
	}
	
	LLVMValueRef visit(IntegerLiteral!false il) {
		return LLVMConstInt(typeGen.visit(il.type), il.value, false);
	}
	
	LLVMValueRef visit(FloatLiteral fl) {
		return LLVMConstReal(typeGen.visit(fl.type), fl.value);
	}
	
	// XXX: character types in backend ?
	LLVMValueRef visit(CharacterLiteral cl) {
		return LLVMConstInt(typeGen.visit(cl.type), cl.value[0], false);
	}
	
	private void updateVariableValue(string name, LLVMValueRef value) {
		LLVMBuildStore(builder, value, symbolStatementGen.variables[name]);
	}
	
	LLVMValueRef visit(AssignExpression e) {
		auto value = visit(e.rhs);
		auto lhs = cast(SymbolExpression) e.lhs;
		
		updateVariableValue(lhs.symbol.name, value);
		
		return value;
	}
	
	LLVMValueRef visit(PreIncrementExpression e) {
		auto value = visit(e.expression);
		auto lvalue = cast(SymbolExpression) e.expression;
		
		value = LLVMBuildAdd(builder, value, LLVMConstInt(typeGen.visit(lvalue.type), 1, false), "");
		
		updateVariableValue(lvalue.symbol.name, value);
		
		return value;
	}
	
	LLVMValueRef visit(PreDecrementExpression e) {
		auto value = visit(e.expression);
		auto lvalue = cast(SymbolExpression) e.expression;
		
		value = LLVMBuildSub(builder, value, LLVMConstInt(typeGen.visit(lvalue.type), 1, false), "");
		
		updateVariableValue(lvalue.symbol.name, value);
		
		return value;
	}
	
	LLVMValueRef visit(PostIncrementExpression e) {
		auto value = visit(e.expression);
		auto lvalue = cast(SymbolExpression) e.expression;
		
		auto updatedValue = LLVMBuildAdd(builder, value, LLVMConstInt(typeGen.visit(lvalue.type), 1, false), "");
		
		updateVariableValue(lvalue.symbol.name, updatedValue);
		
		return value;
	}
	
	LLVMValueRef visit(PostDecrementExpression e) {
		auto value = visit(e.expression);
		auto lvalue = cast(SymbolExpression) e.expression;
		
		auto updatedValue = LLVMBuildSub(builder, value, LLVMConstInt(typeGen.visit(lvalue.type), 1, false), "");
		
		updateVariableValue(lvalue.symbol.name, updatedValue);
		
		return value;
	}
	
	private auto handleBinaryOp(alias LLVMBuildOp, BinaryExpression)(BinaryExpression e) {
		return LLVMBuildOp(builder, visit(e.lhs), visit(e.rhs), "");
	}
	
	private auto handleBinaryOp(alias LLVMSignedBuildOp, alias LLVMUnsignedBuildOp, BinaryExpression)(BinaryExpression e) {
		typeGen.visit(e.type);
		if(typeGen.isSigned) {
			return handleBinaryOp!LLVMSignedBuildOp(e);
		} else {
			return handleBinaryOp!LLVMUnsignedBuildOp(e);
		}
	}
	
	LLVMValueRef visit(AddExpression add) {
		return handleBinaryOp!LLVMBuildAdd(add);
	}
	
	LLVMValueRef visit(SubExpression sub) {
		return handleBinaryOp!LLVMBuildSub(sub);
	}
	
	LLVMValueRef visit(MulExpression mul) {
		return handleBinaryOp!LLVMBuildMul(mul);
	}
	
	LLVMValueRef visit(DivExpression div) {
		return handleBinaryOp!(LLVMBuildSDiv, LLVMBuildUDiv)(div);
	}
	
	LLVMValueRef visit(ModExpression mod) {
		return handleBinaryOp!(LLVMBuildSRem, LLVMBuildURem)(mod);
	}
	
	private auto handleLogicalBinary(string operation)(BinaryExpression!operation e) if(operation == "&&" || operation == "||") {
		auto lhs = visit(e.lhs);
		
		auto lhsBB = LLVMGetInsertBlock(builder);
		auto fun = LLVMGetBasicBlockParent(lhsBB);
		auto rhsBB = LLVMAppendBasicBlock(fun, "");
		auto mergeBB = LLVMAppendBasicBlock(fun, "");
		
		static if(operation == "&&") {
			LLVMBuildCondBr(builder, lhs, rhsBB, mergeBB);
		} else {
			LLVMBuildCondBr(builder, lhs, mergeBB, rhsBB);
		}
		
		// Emit then
		LLVMPositionBuilderAtEnd(builder, rhsBB);
		
		auto rhs = visit(e.rhs);
		
		// Conclude that block.
		LLVMBuildBr(builder, mergeBB);
		
		// Codegen of then can change the current block, so we put everything in order.
		rhsBB = LLVMGetInsertBlock(builder);
		LLVMMoveBasicBlockAfter(mergeBB, rhsBB);
		LLVMPositionBuilderAtEnd(builder, mergeBB);
		
		//Generate phi to get the result.
		auto phiNode = LLVMBuildPhi(builder, typeGen.visit(e.type), "");
		
		LLVMValueRef[2] incomingValues;
		incomingValues[0] = lhs;
		incomingValues[1] = rhs;
		LLVMBasicBlockRef[2] incomingBlocks;
		incomingBlocks[0] = lhsBB;
		incomingBlocks[1] = rhsBB;
		LLVMAddIncoming(phiNode, incomingValues.ptr, incomingBlocks.ptr, incomingValues.length);
		
		return phiNode;
	}
	
	LLVMValueRef visit(LogicalAndExpression e) {
		return handleLogicalBinary(e);
	}
	
	LLVMValueRef visit(LogicalOrExpression e) {
		return handleLogicalBinary(e);
	}
	
	LLVMValueRef visit(SymbolExpression e) {
		return LLVMBuildLoad(builder, symbolStatementGen.variables[e.symbol.name], "");
	}
	
	private auto handleComparaison(LLVMIntPredicate predicate, BinaryExpression)(BinaryExpression e) {
		return handleBinaryOp!(function(LLVMBuilderRef builder, LLVMValueRef lhs, LLVMValueRef rhs, const char* name) {
			return LLVMBuildICmp(builder, predicate, lhs, rhs, name);
		})(e);
	}
	
	private auto handleComparaison(LLVMIntPredicate signedPredicate, LLVMIntPredicate unsignedPredicate, BinaryExpression)(BinaryExpression e) {
		// TODO: implement type comparaison.
		// assert(e.lhs.type == e.rhs.type);
		
		typeGen.visit(e.lhs.type);
		
		if(typeGen.isSigned) {
			return handleComparaison!signedPredicate(e);
		} else {
			return handleComparaison!unsignedPredicate(e);
		}
	}
	
	LLVMValueRef visit(EqualityExpression e) {
		return handleComparaison!(LLVMIntPredicate.EQ)(e);
	}
	
	LLVMValueRef visit(NotEqualityExpression e) {
		return handleComparaison!(LLVMIntPredicate.NE)(e);
	}
	
	LLVMValueRef visit(LessExpression e) {
		return handleComparaison!(LLVMIntPredicate.SLT, LLVMIntPredicate.ULT)(e);
	}
	
	LLVMValueRef visit(LessEqualExpression e) {
		return handleComparaison!(LLVMIntPredicate.SLE, LLVMIntPredicate.ULE)(e);
	}
	
	LLVMValueRef visit(GreaterExpression e) {
		return handleComparaison!(LLVMIntPredicate.SGT, LLVMIntPredicate.UGT)(e);
	}
	
	LLVMValueRef visit(GreaterEqualExpression e) {
		return handleComparaison!(LLVMIntPredicate.SGE, LLVMIntPredicate.UGE)(e);
	}
	
	LLVMValueRef visit(PadExpression e) {
		auto type = typeGen.visit(e.type);
		
		typeGen.visit(e.expression.type);
		if(typeGen.isSigned) {
			return LLVMBuildSExt(builder, visit(e.expression), type, "");
		} else {
			return LLVMBuildZExt(builder, visit(e.expression), type, "");
		}
	}
	
	LLVMValueRef visit(TruncateExpression e) {
		return LLVMBuildTrunc(builder, visit(e.expression), typeGen.visit(e.type), "");
	}
	
	LLVMValueRef visit(CallExpression c) {
		LLVMValueRef[] arguments;
		arguments.length = c.arguments.length;
		
		foreach(i, arg; c.arguments) {
			arguments[i] = visit(arg);
		}
		
		auto name = toStringz((cast(SymbolExpression) c.callee).symbol.name);
		return LLVMBuildCall(builder, LLVMGetNamedFunction(symbolStatementGen.dmodule, name), arguments.ptr, cast(uint) arguments.length, "");
	}
}

import d.ast.type;

class TypeGen {
	bool isSigned;
	
final:
	LLVMTypeRef visit(Type t) {
		return this.dispatch!(function LLVMTypeRef(Type t) {
			auto msg = typeid(t).toString() ~ " is not supported.";
			
			import sdc.terminal;
			outputCaretDiagnostics(t.location, msg);
			
			assert(0, msg);
		})(t);
	}
	
	LLVMTypeRef visit(BooleanType t) {
		isSigned = false;
		
		return LLVMInt1Type();
	}
	
	LLVMTypeRef visit(IntegerType t) {
		isSigned = !(t.type % 2);
		
		final switch(t.type) {
				case Integer.Byte, Integer.Ubyte :
					return LLVMInt8Type();
				
				case Integer.Short, Integer.Ushort :
					return LLVMInt16Type();
				
				case Integer.Int, Integer.Uint :
					return LLVMInt32Type();
				
				case Integer.Long, Integer.Ulong :
					return LLVMInt64Type();
		}
	}
	
	LLVMTypeRef visit(FloatType t) {
		isSigned = true;
		
		final switch(t.type) {
				case Float.Float :
					return LLVMFloatType();
				
				case Float.Double :
					return LLVMDoubleType();
				
				case Float.Real :
					return LLVMX86FP80Type();
		}
	}
	
	// XXX: character type in the backend ?
	LLVMTypeRef visit(CharacterType t) {
		isSigned = false;
		
		final switch(t.type) {
				case Character.Char :
					return LLVMInt8Type();
				
				case Character.Wchar :
					return LLVMInt16Type();
				
				case Character.Dchar :
					return LLVMInt32Type();
		}
	}
}
