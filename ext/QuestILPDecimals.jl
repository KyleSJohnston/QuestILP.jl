module QuestILPDecimals

using Decimals: Decimal
using QuestILP: ILPValue

Base.print(io::IO, x::ILPValue{Decimal}) = print(io, x.value, 'd')

end  # module
