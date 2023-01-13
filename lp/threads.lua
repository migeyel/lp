local t = {}
return { t = t, register = function(f) t[#t + 1] = f end }
